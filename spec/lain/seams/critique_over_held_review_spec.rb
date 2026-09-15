# frozen_string_literal: true

require "json"
require "stringio"
require "timeout"
require "tmpdir"

# `/critique` typed while a changeset review is held: a real Outbox holding a
# real Review::Session over a real git repository, the real SkillDispatch the
# repl stack builds, real RoleSpawn children and a real checkout of the
# reviewed head -- with only the provider replaced, so every request a child
# sends is captured and can be read back.
#
# The working tree carries an UNCOMMITTED marker line throughout. The property
# is that it reaches nothing: not a child's prompt, and not what a child's own
# read_file sees, because that read lands in the checkout rather than the tree.
RSpec.describe "a critique of a held review", :seam do
  def marker = "UNCOMMITTED MARKER nobody reviewed"

  around do |example|
    Dir.mktmpdir("lain-critique-seam") do |root|
      @root = File.realpath(root)
      @repo = File.join(@root, "repo")
      FileUtils.cp_r(SeedRepo.at({ "lib.rb" => "base line\n" }), @repo)
      @base = git("rev-parse", "HEAD").strip
      git("checkout", "-q", "-b", "feature")
      example.run
    end
  end

  def git(*)
    shell = Mixlib::ShellOut.new("git", "-C", @repo, *, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
    shell.run_command.error!
    shell.stdout
  end

  def commit(files, message)
    files.each do |path, body|
      FileUtils.mkdir_p(File.dirname(File.join(@repo, path)))
      File.binwrite(File.join(@repo, path), body)
    end
    git("add", "-A")
    git("commit", "-q", "-m", message)
  end

  def dirty_the_working_tree = File.write(File.join(@repo, "lib.rb"), "reviewed line\n#{marker}\n")

  def worktrees = git("worktree", "list", "--porcelain").scan(/^worktree /).size

  def review_round
    source = Lain::Review::Source::LocalBranch.new(base: @base, repo_root: @repo)
    Lain::Review::Session.open(changeset: Lain::Review::Changeset.new(source:), journal: [], source: "local_branch")
  end

  def held_outbox(outbox = Lain::Review::Submit::Outbox.new)
    outbox.hold(session: review_round, number: nil, label: "branch feature")
  end

  def text(words) = Lain::Response.new(content: [{ "type" => "text", "text" => words }], stop_reason: :end_turn)

  def reads(path)
    Lain::Response.new(content: [{ "type" => "tool_use", "id" => "tu_read", "name" => "read_file",
                                   "input" => { "path" => path } }], stop_reason: :tool_use)
  end

  def library = @library ||= Lain::Skill::Library.load(root: @repo)

  def child_context = Lain::Context.new(model: "critic-model", max_tokens: 256)

  def role_spawn(provider)
    union = Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new, Lain::Tools::Glob.new,
                               Lain::Tools::Grep.new])
    Lain::Skill::RoleSpawn.new(provider:, context_factory: -> { child_context }, toolset: union,
                               parent: Lain::Timeline.empty(store: Lain::Store.new), slots: library.slots,
                               tool_middleware: ToolRegistry::UNGUARDED)
  end

  let(:journal) { [] }

  # The exe's backend with its provider replaced, for the chats run below.
  let(:offline_backend_class) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:)
        super(options)
        @mock = mock
      end

      def provider(**) = @mock
    end
  end

  # A server that reports the window it serves, so the run's book is one a
  # critique may size against.
  let(:provider_class) { Class.new(Lain::Provider::Mock) { def context_window_tokens(_model) = 32_768 } }

  def stack(provider, outbox: held_outbox, window_tokens: 32_768)
    Lain::CLI::ReplMiddleware.build(
      role_spawn: role_spawn(provider), library:, outbox:, journal:,
      window: Lain::CLI::Backend::WindowBook::Served.new(model: "critic-model", window_tokens:),
      checkouts: Lain::Review::Critique::Checkouts.new(repo_root: @repo, root: File.join(@root, "worktrees"))
    )
  end

  def typed(stack, line)
    seen = nil
    result = stack.call({ text: line, agent: :the_agent }) do |env|
      seen = env
      env.merge(response: "a parent turn ran")
    end
    [result, seen]
  end

  def payloads(provider) = provider.requests.map { |request| Lain::Canonical.dump(request.cache_payload) }

  # The tool_result a child's read came back as, out of the request that
  # carried it to the model.
  def read_results(provider)
    blocks = provider.requests.flat_map(&:messages).flat_map { |message| Array(message["content"]) }
    blocks.select { |block| block.is_a?(Hash) && block["type"] == "tool_result" }
          .map { |block| JSON.generate(block["content"]) }
  end

  describe "a critique of a held review never sees the working tree" do
    before do
      commit({ "lib.rb" => "reviewed line\n" }, "the reviewed change")
      dirty_the_working_tree
    end

    it "sends no child request containing the uncommitted change, and each one the reviewed hunks" do
      provider = Lain::Provider::Mock.new(responses: [reads("lib.rb"), text("lib.rb reads cleanly")])

      result, seen = typed(stack(provider), "/critique")

      expect(seen).to be_nil
      expect(payloads(provider)).not_to be_empty
      expect(payloads(provider)).to all(satisfy { |payload| !payload.include?(marker) })
      expect(payloads(provider).first).to include("+reviewed line", "-base line")
      expect(result.fetch(:response).text).to include("lib.rb reads cleanly")
    end

    it "lets a child's own read_file see the committed bytes, not the marker line" do
      provider = Lain::Provider::Mock.new(responses: [reads("lib.rb"), text("done")])

      typed(stack(provider), "/critique")

      expect(read_results(provider)).not_to be_empty
      expect(read_results(provider)).to all(include("reviewed line"))
      expect(read_results(provider)).to all(satisfy { |result| !result.include?(marker) })
    end

    # Counted from INSIDE the child's request as well as after, so a critique
    # that never cut a checkout cannot pass as one that released it.
    it "holds a checkout while the child reads, and releases it once the critique is done" do
      provider = Lain::Provider::Mock.new(responses: [text("done")])
      during = []
      allow(provider).to receive(:complete).and_wrap_original do |original, *args, **kwargs|
        during << worktrees
        original.call(*args, **kwargs)
      end

      typed(stack(provider), "/critique")

      expect(during).to eq([2])
      expect(worktrees).to eq(1)
    end

    # An Interrupt RAISED inside a child's provider call: what this pins is the
    # checkout's `ensure`, not how a human's Ctrl-C reaches a running critique.
    it "releases the checkout when an Interrupt is raised inside a child's provider call" do
      provider = Lain::Provider::Mock.new(responses: [text("done")])
      during = []
      allow(provider).to receive(:complete) do
        during << worktrees
        raise Interrupt
      end

      expect { typed(stack(provider), "/critique") }.to raise_error(Interrupt)
      expect(during).to eq([2])
      expect(worktrees).to eq(1)
    end
  end

  describe "a large changeset is critiqued in chunks, not truncated" do
    before do
      commit({ "lib/one.rb" => "one\n" }, "first change")
      commit({ "lib/two.rb" => "two\n" }, "second change")
    end

    it "spawns one child per chunk, and the merged findings name every chunk" do
      provider = Lain::Provider::Mock.new(responses: [text("a finding")])

      result, _seen = typed(stack(provider), "/critique")

      expect(provider.requests.size).to eq(2)
      expect(result.fetch(:response).text)
        .to include("chunk 1 of 2 -- first change", "lib/one.rb", "chunk 2 of 2 -- second change", "lib/two.rb")
      expect(journal.map(&:ordinal)).to eq([1, 2])
    end
  end

  describe "chunks fit the child's window" do
    before do
      files = Array.new(70).each_index.to_h do |index|
        lines = Array.new(100) { |line| "line #{line} of file #{index}".ljust(40, ".") }
        [format("lib/f%02d.rb", index), "#{lines.join("\n")}\n"]
      end
      commit(files, "seven thousand lines")
    end

    it "keeps every child request under a 32768-token window" do
      provider = Lain::Provider::Mock.new(responses: [text("a finding")])

      typed(stack(provider), "/critique")

      estimates = payloads(provider).map { |payload| ((payload.bytesize + 3) / 4) + 256 }
      expect(estimates.size).to be > 1
      expect(estimates).to all(be <= 32_768)
    end
  end

  describe "a chunk that cannot fit refuses the critique before any spend" do
    before do
      commit({ "lib/huge.rb" => Array.new(3_700) { |line| "row #{line}".ljust(64, "x") }.join("\n") }, "one big file")
    end

    it "spawns no child, cuts no checkout, and names the file, its estimate and the window" do
      provider = Lain::Provider::Mock.new(responses: [text("never")])

      expect { typed(stack(provider), "/critique") }
        .to raise_error(Lain::Review::Critique::Refused, %r{lib/huge\.rb alone estimates \d{5,} tokens.*32768})
      expect(provider.requests).to be_empty
      expect(worktrees).to eq(1)
    end
  end

  describe "without a held review" do
    it "runs the critique skill in-line as before" do
      provider = Lain::Provider::Mock.new(responses: [text("never")])

      _result, seen = typed(stack(provider, outbox: Lain::Review::Submit::Outbox.new), "/critique some/path")

      expect(seen.fetch(:text)).to start_with(library.renderer.render("critique")).and end_with("some/path")
      expect(provider.requests).to be_empty
    end
  end

  # The terminal the human types at, holding the round into the chat's own
  # outbox just before the first line is read.
  def tty_factory(output, holds)
    history_path = File.join(@root, "history")
    lambda do |channel:, **|
      Class.new(Lain::Frontend::TTY) do
        define_method(:prompt) do |text = "> "|
          holds.shift&.call
          super(text)
        end
      end.new(channel:, output:, input: StringIO.new("/critique\nquit\n"), history_path:)
    end
  end

  # The whole chat, run to its end over one typed `/critique`.
  def run_chat(provider, max_tokens: 256, grace: 5)
    output = StringIO.new
    holds = []
    project = Lain::Project.new(root: @repo, cwd: @repo, kind: :project, detected_by: :flag)
    @wiring = Lain::CLI::Wiring.new(options: { grace: }, chronicle: Lain::CLI::Chronicle::Null.new, project:,
                                    tty_factory: tty_factory(output, holds),
                                    status_feed: instance_double(Lain::StatusFeed, bind_store: nil))
    holds << -> { held_outbox(@wiring.command_surface.outbox) }
    backend = offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: }, mock: provider)
    Timeout.timeout(60) { @wiring.run(backend:, resumed: nil, nvim: nil) }
    @wiring.conductor.close(reason: :exit)
    output.string
  end

  # The same line through the chat CLI::Wiring assembles: the real Surface, its
  # one outbox and the run's own window book. The round is held into THAT
  # outbox at the moment the human would type, because `/review` itself needs
  # an attached editor and what is under test is what `/critique` reaches.
  describe "through the production chat wiring" do
    before do
      commit({ "lib.rb" => "reviewed line\n" }, "the reviewed change")
      dirty_the_working_tree
    end

    it "runs Review::Critique over the held changeset rather than the skill" do
      provider = provider_class.new(responses: [text("the wired critic's finding")])

      output = run_chat(provider)

      expect(provider.requests.size).to eq(1)
      expect(payloads(provider).first).to include("chunk 1 of 1", "+reviewed line")
      expect(payloads(provider).first).not_to include(marker)
      expect(output).to include("the wired critic's finding")
      expect(worktrees).to eq(1)
    end
  end

  # A child is invited to read, and a read's result rides its next request, so
  # a first request packed to the window leaves the second nowhere to go.
  describe "production-wired chunks leave room for the child's reads" do
    before do
      files = Array.new(70).each_index.to_h do |index|
        lines = Array.new(100) { |line| "line #{line} of file #{index}".ljust(40, ".") }
        [format("lib/f%02d.rb", index), "#{lines.join("\n")}\n"]
      end
      commit(files, "seven thousand lines")
    end

    it "keeps every first request under 60% of a 32,768-token window at the chat's response reserve" do
      provider = provider_class.new(responses: [text("a finding")])

      run_chat(provider, max_tokens: 4_096)

      estimates = payloads(provider).map { |payload| ((payload.bytesize + 3) / 4) + 4_096 }
      expect(estimates.size).to be > 1
      expect(estimates).to all(be < 0.6 * 32_768)
    end
  end

  # The human's keys, delivered as production delivers them: real OS signals,
  # into the chat CLI::Wiring runs under `Conductor#guard`, while the first
  # chunk's child is mid-request. The critique runs inside the line's
  # `Conductor#supervise`, so they reach it exactly as they reach a model turn.
  describe "a human stopping a running critique" do
    around do |example|
      saved = Lain::CLI::Signals::MAP.keys.to_h { |name| [name, Signal.trap(name, "DEFAULT")] }
      example.run
    ensure
      saved.each { |name, handler| Signal.trap(name, handler) }
    end

    before do
      commit({ "lib/one.rb" => "one\n" }, "first change")
      commit({ "lib/two.rb" => "two\n" }, "second change")
      commit({ "lib/three.rb" => "three\n" }, "third change")
    end

    # Each child request counts the checkouts standing, and the first sends
    # `signals` and then parks the way a slow model does.
    def interrupted_by(*signals)
      requests = @requests = []
      checkouts = -> { worktrees }
      Class.new(provider_class) do
        define_method(:complete) do |request, **kwargs|
          requests << checkouts.call
          signals.each { |name| Process.kill(name, Process.pid) } if requests.size == 1
          Async::Task.current.sleep(10)
          super(request, **kwargs)
        end
      end.new(responses: [text("a finding")])
    end

    it "stops the in-flight child on a double Ctrl-C, spawns no further child and releases the checkout" do
      output = run_chat(interrupted_by("INT", "INT"))

      expect(@requests).to eq([2])
      expect(worktrees).to eq(1)
      expect(output).not_to include("a finding")
      expect(@wiring.conductor).to be_closed
    end

    it "starts the grace countdown on one SIGTERM, and stops the critique when the window runs out" do
      output = run_chat(interrupted_by("TERM"), grace: 0.3)

      expect(@requests).to eq([2])
      expect(worktrees).to eq(1)
      expect(output).not_to include("a finding")
    end
  end
end
