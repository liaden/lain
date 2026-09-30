# frozen_string_literal: true

require "async"
require "fileutils"
require "mixlib/shellout"
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

  # Scrubbed exactly as the subject scrubs, so a pre-commit hook's
  # GIT_INDEX_FILE never points these calls at lain's own index.
  def git(*args, dir: repo)
    shell = Mixlib::ShellOut.new("git", "-C", dir, *args, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
    shell.run_command.error!
    shell.stdout.strip
  end

  def contains?(commit, branch = "feat")
    Mixlib::ShellOut.new("git", "-C", repo, "merge-base", "--is-ancestor", commit, branch,
                         environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command.exitstatus.zero?
  end

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

  it "brings a child's commit back to the branch the chat launched on" do
    script.push(works)

    dispatch(wired)

    expect(contains?(@c1)).to be(true)
    expect(handbacks.map(&:outcome)).to eq([:merged])
    expect(handbacks.last.fast_forward).to be(true)
  end

  it "anchors the work and names the dirty files, rather than merging into a human's uncommitted edits" do
    script.push(works(file: "README", body: "worker\n"))
    seed = git("rev-parse", "feat")
    File.write(File.join(repo, "README"), "human edit\n")

    result = dispatch(wired)

    expect(result.content).to include("uncommitted").and include("README")
    ref = handbacks.last.ref
    expect(ref).to start_with("refs/lain/worker/")
    expect(git("rev-parse", ref)).to eq(@c1)
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

    it "rebases a child's commit onto the moved branch, so it comes back as a fast-forward" do
      script.push(lambda do |_request|
        @c1 = commit(worktree, "work.txt", "c1\n", "c1")
        @tip = commit(repo, "notes.txt", "moved\n", "T")
        text("done")
      end)

      dispatch(wired)

      expect(handbacks.first.sync).to eq(:synced)
      expect(git("rev-parse", "feat^")).to eq(@tip)
      expect(git("show", "feat:work.txt")).to eq("c1")
      expect(git("rev-parse", "feat")).not_to eq(@c1)
      expect(handbacks.first.fast_forward).to be(true)
      expect(handbacks.first.sha).to eq(git("rev-parse", "feat"))
    end

    it "asks a child whose rebase conflicts once, records the attempt and its words, then spawns a merge_resolver" do
      script.push(conflicting, text("I could not rebase it"), text("resolved"))

      dispatch(wired)

      expect(asked_to_rebase).to eq(1)
      expect(handbacks.first.attempts)
        .to eq([attempt("lain", 1, "conflicted"), attempt("worker", 1, "conflicted")])
      expect(handbacks.first.detail).to eq("I could not rebase it")
      expect(handbacks.first.outcome).to eq(:conflicted)
      expect(resolver_briefs).to eq(1)
      expect(git("rev-parse", "feat")).to eq(@tip)
    end

    context "with rebase_retries = 0" do
      before do
        write_config(repo, "isolation rebase_retries: 0\n")
      end

      it "asks for no rebase, and the handback merges as before" do
        script.push(conflicting, text("resolved"))

        dispatch(wired)

        expect(asked_to_rebase).to eq(0)
        expect(handbacks.first.sync).to eq(:disabled)
        expect(handbacks.first.outcome).to eq(:conflicted)
        expect(resolver_briefs).to eq(1)
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
      expect(contains?(@c1)).to be(true)
    end
  end
end
