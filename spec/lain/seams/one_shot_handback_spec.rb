# frozen_string_literal: true

require "async"
require "fileutils"
require "tmpdir"

# Scripted like {Lain::Provider::Mock}, except that a step may be a lambda, run
# when the child reaches that call. That is how a "worker" commits in its own
# checkout, and the working branch moves under it, at a moment the spec
# chooses, without the child holding a shell.
class OneShotHandbackProvider < Lain::Provider::Mock
  def complete(request, on_stream_started: nil)
    step = super
    step.respond_to?(:call) ? step.call(request) : step
  end
end

# Everything real between the chat and git: the backend `--isolation worktree`
# resolves, the Supervisor and ToolsetBuild CLI::Wiring assembles, the role
# spawn a dev child comes from, the handoff and the throwaway repository. Only
# the provider is scripted.
RSpec.describe "A one-shot child's commits come home on the chat path", :seam do
  let(:channel) { RecordingChannel.new }
  # The lease and handback records land in the session record, not on the
  # display Channel, so they are read back off a recording chronicle.
  let(:record) { RecordingChannel.new }
  let(:chronicle) { Lain::CLI::Chronicle.new(journal: record, journal_path: "one-shot-handback-session.ndjson") }
  let(:script) { [] }
  let(:provider) { OneShotHandbackProvider.new(responses: script) }
  let(:status_feed) { instance_double(Lain::StatusFeed, bind_store: nil) }
  let(:offline_backend_class) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:, root: Dir.pwd)
        super(options, root:)
        @mock = mock
      end

      def provider(**) = @mock
    end
  end
  let(:backend) { offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: provider) }

  around do |example|
    Dir.mktmpdir("lain-handback-repo") do |repo|
      Dir.mktmpdir("lain-handback-state") do |state|
        @repo = File.realpath(repo)
        FileUtils.cp_r("#{SeedRepo.at(seed_files)}/.", @repo)
        git("switch", "-q", "-c", "feat")
        with_env("XDG_STATE_HOME" => File.realpath(state)) { Dir.chdir(@repo) { example.run } }
      end
    end
  end

  attr_reader :repo

  def seed_files = { "README" => "seed\n", "notes.txt" => "seed\n" }

  def git(*args, dir: repo) = SeedRepo.git(dir, *args).stdout.strip

  def commit(dir, file, body, message)
    File.write(File.join(dir, file), body)
    git("add", file, dir:)
    git("commit", "-q", "-m", message, dir:)
    git("rev-parse", "HEAD", dir:)
  end

  # The checkout the child runs in: the path on the lease record the run
  # journalled when it acquired one.
  def worktree
    record.events.grep(Lain::Telemetry::IsolationLease).reverse.find { |lease| lease.kind == :acquired }.path
  end

  def text(body) = Lain::Response.new(content: [{ "type" => "text", "text" => body }], stop_reason: :end_turn)

  # The worker's turn: it commits c1 in its own checkout and answers.
  def works(file: "work.txt", body: "c1\n")
    lambda do |_request|
      @c1 = commit(worktree, file, body, "c1")
      text("done")
    end
  end

  def wired(options = {})
    wiring = Lain::CLI::Wiring.new(options: { grace: 5, isolation: "worktree", **options },
                                   chronicle:, status_feed:)
    recorder, session = wiring.run_state(nil)
    wiring.wire_agent(channel:, recorder:, session:, backend:, notice: ->(_line) {})
    wiring
  end

  def dispatch(wiring) = Sync { dispatch_in(wiring) }

  def dispatch_in(wiring) = wiring.role_spawn.call(:dev, :fresh, "do the work")

  def handbacks = record.events.grep(Lain::Telemetry::Handback)

  def queued
    Lain::Isolation::MergeCoordinator::Spool.new(
      Lain::Isolation::MergeCoordinator::Home.for(repo_root: repo, branch: "feat")
    ).pending.map { |entry| entry.worker.sha }
  end

  it "queues a child's commit for the branch the chat launched on, and merges nothing" do
    script.push(works)
    seed = git("rev-parse", "feat")

    result = dispatch(wired)

    expect(git("rev-parse", "feat")).to eq(seed)
    expect(git("rev-parse", handbacks.last.ref)).to eq(@c1)
    expect(queued).to eq([@c1])
    expect(handbacks.map(&:outcome)).to eq([:queued])
    expect(result.content).to include("lain land wait")
  end

  it "queues the work past a human's uncommitted edits, and leaves those edits alone" do
    script.push(works(file: "README", body: "worker\n"))
    seed = git("rev-parse", "feat")
    File.write(File.join(repo, "README"), "human edit\n")

    dispatch(wired)

    ref = handbacks.last.ref
    expect(ref).to start_with("refs/lain/worker/")
    expect(git("rev-parse", ref)).to eq(@c1)
    expect(queued).to eq([@c1])
    expect(git("rev-parse", "feat")).to eq(seed)
    expect(File.read(File.join(repo, "README"))).to eq("human edit\n")
  end

  # A child that raised is surrendered rather than handed back, and its
  # checkout is still read first: work it wrote and never committed is named
  # on the record, not reported as a clean tree with nothing to do.
  it "hands back a leased child that wrote a file and then hit its ceiling as dirty" do
    path = nil
    script.push(lambda do |_request|
      path ||= worktree.tap { |dir| File.write(File.join(dir, "scratch.txt"), "never committed\n") }
      tool_response(["c1", "no_such_tool", {}])
    end)

    expect { dispatch(wired) }.to raise_error(Lain::Agent::Budget::Exceeded)

    expect(handbacks.first).to have_attributes(sync: :dirty, dirty: true, path:)
  end

  # A second stop -- an ancestor task, a reactor teardown -- landing while the
  # stopped child's checkout is synced must not skip the handoff that releases
  # its lease: the worktree would stay on disk with nothing on the record.
  it "releases a stopped child's lease and records its handback when a second stop lands in the sync" do
    parked = false
    entered = false
    path = nil
    script.push(lambda do |_request|
      path = worktree
      git("commit", "--allow-empty", "-q", "-m", "c1", dir: path)
      parked = true
      sleep
    end)
    allow(Lain::Isolation::SelfSync).to receive(:new).and_wrap_original do |build, **config|
      build.call(**config).tap do |sync|
        allow(sync).to receive(:call).and_wrap_original do |original, *args, **kw|
          entered = true
          original.call(*args, **kw)
        end
      end
    end
    wiring = wired

    Sync do |task|
      run = task.async { dispatch_in(wiring) }
      pumped_until(task) { parked }
      run.stop
      pumped_until(task) { entered }
      run.stop
      pumped_until(task, timeout: 10) { run.finished? }
    end

    released = record.events.grep(Lain::Telemetry::IsolationLease).count { |lease| lease.kind == :released }
    expect([handbacks.size, released, Dir.exist?(path)]).to eq([1, 1, false])
  end

  # What the sync did rides the handback record itself, so the first record
  # for the dev child is the one these read.
  describe "the worker syncs itself before it hands back" do
    # What the LAST message of a request said: a follow-up ask and a resolver's
    # brief are each the newest user turn of the request they start.
    def asked(phrase)
      provider.requests.count do |request|
        Array(request.messages.last["content"]).grep(Hash).any? { |block| block["text"].to_s.include?(phrase) }
      end
    end

    def asked_to_rebase = asked("git rebase --continue")

    def resolver_briefs = asked("the merge conflicted")

    def attempt(by, conflicts, outcome) = { "by" => by, "conflicts" => conflicts, "outcome" => outcome }

    # The worker rewrites README on the base it was cut from, while feat
    # rewrites it too: a rebase of one onto the other cannot land cleanly.
    def conflicting
      lambda do |_request|
        @c1 = commit(worktree, "README", "worker\n", "c1")
        @tip = commit(repo, "README", "tip\n", "T")
        text("done")
      end
    end

    it "rebases a child's commit onto the moved branch before it is queued" do
      script.push(lambda do |_request|
        @c1 = commit(worktree, "work.txt", "c1\n", "c1")
        @tip = commit(repo, "notes.txt", "moved\n", "T")
        text("done")
      end)

      dispatch(wired)

      expect(handbacks.first.sync).to eq(:synced)
      rebased = git("rev-parse", handbacks.first.ref)
      expect(git("rev-parse", "#{rebased}^")).to eq(@tip)
      expect(git("show", "#{rebased}:work.txt")).to eq("c1")
      expect(queued).to eq([rebased])
      expect(git("rev-parse", "feat")).to eq(@tip)
    end

    it "asks a child whose rebase conflicts once, records the attempt and its words, then queues it unresolved" do
      script.push(conflicting, text("I could not rebase it"))

      dispatch(wired)

      expect(asked_to_rebase).to eq(1)
      expect(handbacks.first.attempts)
        .to eq([attempt("lain", 1, "conflicted"), attempt("worker", 1, "conflicted")])
      expect(handbacks.first.detail).to eq("I could not rebase it")
      expect(handbacks.first.outcome).to eq(:queued)
      expect(resolver_briefs).to eq(0)
      expect(queued).to eq([@c1])
      expect(git("rev-parse", "feat")).to eq(@tip)
    end

    context "with rebase_retries = 0" do
      before do
        write_config(repo, "isolation rebase_retries: 0\n")
      end

      it "asks for no rebase, and queues the worker's commit as it was" do
        script.push(conflicting)

        dispatch(wired)

        expect(asked_to_rebase).to eq(0)
        expect(handbacks.first.sync).to eq(:disabled)
        expect(handbacks.first.outcome).to eq(:queued)
        expect(queued).to eq([@c1])
      end
    end

    it "does not rebase a child that left uncommitted work, and says so on the record and to the parent" do
      seed = git("rev-parse", "feat")
      path = nil
      script.push(lambda do |_request|
        path = worktree
        @c1 = commit(worktree, "work.txt", "c1\n", "c1")
        File.write(File.join(worktree, "scratch.txt"), "never committed\n")
        commit(repo, "notes.txt", "moved\n", "T")
        text("done")
      end)

      result = dispatch(wired)

      expect(handbacks.first).to have_attributes(sync: :dirty, dirty: true, path:)
      expect(result.content).to include("the worker left uncommitted changes at #{path}; they were not handed back")
      expect(git("rev-parse", "#{@c1}^")).to eq(seed)
      expect(queued).to eq([@c1])
    end
  end
end
