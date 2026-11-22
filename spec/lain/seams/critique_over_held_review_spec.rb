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

# A provider refusing a prompt WHOLE for not fitting the context it loaded,
# raised the way ollama raises one: the figures on the {Lain::WindowExceeded}
# duck, and the server's JSON body as the message. That body is what a chunk's
# finding must not become.
class CritiqueSeamRefusal < Lain::Error
  include Lain::WindowExceeded

  BODY = '{"error":"model requires more system memory than is available"}'
end

# The frontend's review half, reduced to what `/review` asks of it: the REAL text surface and a view whose
# render inlet swallows every call, because no editor is attached in this seam.
class CritiqueSeamEditor
  class Inlet
    def method_missing(_name, *) = nil
    def respond_to_missing?(*) = true
  end

  def initialize(sink)
    @surface = Lain::Review::Surface::Text.new(sink:)
    diff = Lain::Frontend::Neovim::ChangesetDiff.new(rpc: Inlet.new)
    @view = Lain::Frontend::Neovim::ReviewView.new(changesets: diff)
  end

  attr_reader :view

  def held_review_notes = 0
  def review_surface = @surface
  def review_view = @view
  def bind_changeset_review(_review) = nil
end

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

  def git(*) = SeedRepo.git(@repo, *).stdout

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
                               parent: CoreGraph.timeline, slots: library.slots,
                               tool_middleware: ToolRegistry::UNGUARDED)
  end

  let(:journal) { [] }

  # The exe's backend with its provider replaced, for the chats run below.
  let(:offline_backend_class) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:, root: Dir.pwd)
        super(options, root:)
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
    result = stack.call({ text: line, agent: instance_double(Lain::Agent, :command= => nil) }) do |env|
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

  describe "a critique another command asks for, over the round it opened" do
    before { commit({ "lib.rb" => "reviewed line\n" }, "the reviewed change") }

    def dispatch_of(stack) = stack.to_a.find { |member| member.is_a?(Lain::Middleware::SkillDispatch) }

    it "answers what the typed line answers, and spends nothing until it is called" do
      typed_provider = Lain::Provider::Mock.new(responses: [text("a finding")])
      typed_answer = typed(stack(typed_provider), "/critique the error paths").first.fetch(:response).text
      provider = Lain::Provider::Mock.new(responses: [text("a finding")])

      prepared = dispatch_of(stack(provider)).critique("the error paths")

      expect(provider.requests).to be_empty
      expect(prepared.call).to eq(typed_answer)
    end

    it "refuses a blank model= before a checkout is cut or a child spawned" do
      provider = Lain::Provider::Mock.new(responses: [text("a finding")])

      expect { dispatch_of(stack(provider)).critique("model= the error paths") }
        .to raise_error(Lain::Review::Critique::Refused, /model/)
      expect(provider.requests).to be_empty
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

  # A window sized for the changeset can still be refused by the runner that
  # actually loads it -- ollama reloads at the request's own num_ctx -- and a
  # chunk refused that way is the one finding nobody can read as findings.
  describe "a chunk whose child the provider refuses as over-window" do
    before do
      commit({ "lib/one.rb" => "one\n" }, "first change")
      commit({ "lib/two.rb" => "two\n" }, "second change")
    end

    def refuse_whole
      figures = { prompt_tokens: 41_000, window_tokens: 32_768, source: "ollama" }
      raise CritiqueSeamRefusal.new(CritiqueSeamRefusal::BODY, **figures)
    end

    # The FIRST child only: the rest answer, so an example can tell a refusal
    # that cost one chunk from one that cost the critique.
    def refusing_first
      provider = Lain::Provider::Mock.new(responses: [text("a finding")])
      seen = 0
      allow(provider).to receive(:complete).and_wrap_original do |original, *args, **kwargs|
        seen += 1
        refuse_whole if seen == 1
        original.call(*args, **kwargs)
      end
      provider
    end

    it "words that chunk with the chunk and the window, keeps the other chunk's findings, and leaks no body" do
      result, _seen = typed(stack(refusing_first), "/critique")

      findings = result.fetch(:response).text
      expect(findings).to include("chunk 1 of 2", "32768-token context", "a finding")
      expect(findings.scan("chunk 1 of 2").size).to eq(1)
      expect(findings).not_to include(CritiqueSeamRefusal::BODY)
      expect(journal.map(&:outcome)).to eq(%w[failed answered])
      expect(worktrees).to eq(1)
    end

    it "names the child in the refused chunk's own text" do
      typed(stack(refusing_first), "/critique")

      expect(journal.first.text).to start_with("chunk 1 of 2")
      expect(journal.first.text).to include("diff_critic", "41000")
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
  # outbox just before the first prompt is drawn.
  def tty_factory(output, holds)
    history_path = File.join(@root, "history")
    lambda do |channel:, **|
      Class.new(Lain::Frontend::TTY) do
        define_method(:print_prompt) do |text|
          holds.shift&.call
          super(text)
        end
      end.new(channel:, output:, history_path:)
    end
  end

  # What runs just before the first prompt: the round held directly, or an editor attached for `/review` to open one.
  def held_before_first_prompt(editor)
    return -> { held_outbox(@wiring.command_surface.outbox) } unless editor

    -> { @wiring.command_surface.env.replies.bind_review_editor(editor) }
  end

  # The whole chat, run to its end over one typed `/critique`.
  def run_chat(provider, max_tokens: 256, grace: 5, stdin: StringIO.new("/critique\nquit\n"), editor: nil,
               record: nil)
    output = StringIO.new
    holds = []
    project = Lain::Project.new(root: @repo, cwd: @repo, kind: :project, detected_by: :flag)
    @wiring = Lain::CLI::Wiring.new(human: Lain::CLI::Human.new(kind: :terminal),
                                    options: { grace: }, chronicle: record || Lain::CLI::Chronicle::Null.new, project:,
                                    herdr: Lain::CLI::Wiring::HerdrBinding::Null.new(
                                      tty_factory: tty_factory(output, holds)
                                    ),
                                    status_feed: instance_double(Lain::StatusFeed, bind_store: nil),
                                    stdin:)
    holds << held_before_first_prompt(editor)
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

  # `/review --critique` typed at the real chat: the round opens in the command, and the critique then runs
  # as the line the repl was handed, inside the same supervision a typed `/critique` gets.
  describe "a critique that /review asked for, through the production chat wiring" do
    around do |example|
      saved = Lain::CLI::Signals::MAP.keys.to_h { |name| [name, Signal.trap(name, "DEFAULT")] }
      example.run
    ensure
      saved.each { |name, handler| Signal.trap(name, handler) }
    end

    before { commit({ "lib.rb" => "reviewed line\n" }, "the reviewed change") }

    let(:review_line) { "/review feature --base #{@base} --critique=critics=3" }
    let(:recording) do
      records = Class.new(Array) { def record(entry) = push(entry) }.new
      @records = records
      Class.new(Lain::CLI::Chronicle::Null) { define_method(:record_journal) { records } }.new
    end

    # A line the human finishes while the critique runs. The pipe a pump reads takes no line off a terminal
    # mid-ask, and the wiring has no reader for its rail, so the rail is reached where a producer would.
    def typed_at_the_rail(text)
      @wiring.instance_variable_get(:@rail) << Lain::Frontend::Intake::Line.new(text:, generation: 0)
    end

    # Counts each critic that starts, and the first parks the way a slow model does until a stop ends it.
    def parking_first(started, on_first: nil)
      Class.new(provider_class) do
        define_method(:complete) do |request, **kwargs|
          started << :started
          if started.size == 1 && on_first
            on_first.call
            Async::Task.current.sleep(30)
          end
          super(request, **kwargs)
        end
      end.new(responses: [text("a finding")])
    end

    it "stops the running critic on /stop, starts no other, and does not say no ask is running" do
      started = []
      provider = parking_first(started, on_first: -> { typed_at_the_rail("/stop") })

      output = run_chat(provider, stdin: StringIO.new("#{review_line}\nquit\n"),
                                  editor: CritiqueSeamEditor.new(StringIO.new), record: recording)

      expect(started).to eq([:started])
      expect(output).not_to include(Lain::CLI::Command::Stop::NOTHING_RUNNING)
      expect(worktrees).to eq(1)
    end

    it "lets all 3 critics answer when nobody stops it, and the round holds their notes" do
      started = []
      provider = parking_first(started)

      output = run_chat(provider, stdin: StringIO.new("#{review_line}\nquit\n"),
                                  editor: CritiqueSeamEditor.new(StringIO.new), record: recording)

      expect(started.size).to eq(3)
      expect(@records.select { |entry| entry.respond_to?(:outcome) }.map(&:outcome)).to eq(%w[answered] * 3)
      expect(@wiring.command_surface.outbox).to be_open
      expect(output).to include("3 critics read this chunk")
    end
  end
end
