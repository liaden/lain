# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

# Stands in for the eager tier's local model (A8 wires an Ollama-backed
# {Lain::Oracle::Model}), answering the REAL {Lain::Oracle::Summarize}
# definition so the schema, the Promise, and `#summary` are the production ones
# -- only the network edge is stubbed, exactly as {Lain::Provider::Mock} stubs
# the chat provider.
class WiringSpecSummarizer
  def initialize(text)
    @definition = Lain::Oracle::Summarize.definition
    @text = text
  end

  def ask(_inputs = {}) = @definition.answer("summary" => @text)
end

# The launch block's stand-in for an adopted actor (D2): it builds the child's
# Session from the LEASED WorkerEnv exactly as
# {Lain::Tools::Subagent::ChildBuilder#spawn_agent} does, so what a spec reads
# back is the object the real spawn path constructs.
#
# It answers the LIFECYCLE predicates as well as `#stop`, because that is what
# the actor duck is: {Lain::Supervisor::Registration#state} derives every row's
# state from `stopped?`/`dead?`, and {Lain::Supervisor#stop} reads it on the way
# out to tell a crashed row (surrendered) from a live one (released). A stand-in
# that answered only `#stop` kept passing while that contract widened under it,
# which is precisely how the widening went unnoticed -- so these are honest
# rather than hard-coded: this worker is alive until it is stopped, and never
# crashes.
class WiringSpecWorker
  attr_reader :session, :checkout

  # `checkout` is snapshotted HERE, inside the launch block, while the lease is
  # still live: {Lain::Supervisor#stop} releases it and a worktree release
  # removes the tree, so a spec that looked afterwards could only ever do string
  # math over `#cwd` -- which passes whether or not a checkout was ever created.
  def initialize(worker_env)
    @session = Lain::Session.new(worker_env:)
    @checkout = { exists: Dir.exist?(worker_env.cwd),
                  repo: File.exist?(worker_env.resolve(".git")),
                  seeded: File.exist?(worker_env.resolve("README")) }
    @stopped = false
  end

  def stop
    @stopped = true
    self
  end

  def stopped? = @stopped

  # No fiber to fail, so the only way this worker is dead is by being stopped --
  # {Lain::Tools::Subagent::Actor}'s own distinction, and it keeps every row here
  # out of the crashed branch.
  def dead? = @stopped
end

# Counts the calls to `#start` and is otherwise the chronicle it wraps. T23
# needs an ORDERING claim -- that a config refusal lands before the session
# record is opened -- and `#start` is the moment that record exists: it builds
# the {Lain::SessionRecord::Scribe}, whose constructor writes the header. So
# "start was never called" is exactly "no orphan header on disk", asserted
# without parsing journal bytes.
class WiringSpecStartSpy < SimpleDelegator
  attr_reader :starts

  def initialize(inner)
    super
    @starts = 0
  end

  def start(**)
    @starts += 1
    super
  end
end

RSpec.describe Lain::CLI::Wiring do
  # Provider resolution, context, slots, and spawn policies stay the real
  # Backend's; only the network edge swaps for Provider::Mock, so the whole
  # chat assembly is exercised offline exactly as the exe wires it (T1 AC:
  # the extracted Repl is constructible without the exe).
  let(:offline_backend_class) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:)
        super(options)
        @mock = mock
      end

      def provider(**) = @mock
    end
  end

  let(:mock_provider) do
    Lain::Provider::Mock.new(responses: [
                               Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                  stop_reason: :end_turn)
                             ])
  end
  let(:backend) { offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: mock_provider) }

  # A provider that answers BOTH questions the T10 pin below needs of one: what
  # window it is serving (`Provider#context_window_tokens`, which the base class
  # answers nil for) and a turn whose usage gives `#occupancy` a numerator.
  # 7,079 tokens is the POC's own figure -- 21.6% of a served 32,768 and 86.4%
  # of the conservative fallback, so the two candidate denominators cannot be
  # confused for one another.
  let(:serving_provider) do
    Class.new(Lain::Provider::Mock) do
      def context_window_tokens(_model) = 32_768
    end.new(responses: [
              Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }], stop_reason: :end_turn,
                                 usage: Lain::Usage.new(input_tokens: 7_079, output_tokens: 1))
            ])
  end
  let(:channel) { Lain::Channel.new }
  let(:chronicle) { Lain::CLI::Chronicle::Null.new }
  # status_feed: is required, not defaulted (the Null placeholder is gone); the
  # direct-Wiring path only threads it into the Command::Env's status reader.
  let(:status_feed) { instance_double(Lain::StatusFeed) }
  let(:wiring) { described_class.new(options: { grace: 5 }, chronicle:, status_feed:) }

  def wire_agent
    recorder, session = wiring.run_state(nil)
    wiring.wire_agent(channel:, recorder:, session:, backend:)
  end

  # The 2026-08-05 defect, at the site it fired from: this call built
  # `Lain::Notify.for` unconditionally, so every spec, probe and experiment that
  # reached #wire_agent got the REAL dunstify adapter -- nine notifications
  # landed on a working human's desktop, `appname: lain`, from agents' trees.
  # A fake `dunstify` goes on PATH for the duration so BOTH directions are
  # decided by the subject rather than by whether this box has a notification
  # daemon installed; it is only ever resolved, never executed, because nothing
  # here asks the notifier to notify.
  describe "the desktop notifier" do
    around do |example|
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "dunstify"), "#!/bin/sh\nexit 1\n")
        File.chmod(0o755, File.join(dir, "dunstify"))
        with_env("PATH" => "#{dir}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}", "LAIN_DESKTOP" => nil) do
          example.run
        end
      end
    end

    def notifier_for(**desktop)
      wiring = described_class.new(options: { grace: 5, **desktop }, chronicle:, status_feed:)
      recorder, session = wiring.run_state(nil)
      wiring.wire_agent(channel:, recorder:, session:, backend:)
      wiring.notifier
    end

    it "stays Null for a caller that never asked for the desktop" do
      expect(notifier_for).to be_a(Lain::Notify::Null)
    end

    it "stays Null when the flag is explicitly off, dunstify or not" do
      expect(notifier_for(desktop: false)).to be_a(Lain::Notify::Null)
    end

    # The other half of the gate, and the one that says the human lost nothing:
    # `lain chat` passes --desktop's default (true, pinned in
    # spec/lain/cli_spec.rb), so a human at a terminal on a box with dunstify
    # gets the real adapter exactly as before.
    it "is the real adapter when the run consents and dunstify resolves" do
      expect(notifier_for(desktop: true)).to be_a(Lain::Notify)
    end
  end

  describe "#wire_agent" do
    it "builds the Agent over the injected backend's provider, no exe involved" do
      agent = wire_agent
      expect(agent).to be_a(Lain::Agent)
      expect(agent.ask("ping").text).to eq("settled")
      expect(mock_provider.call_count).to eq(1)
    end

    # The parent handle is ONE Proc, equal?-shared by AskHuman::Notifying and
    # Subagent::Seam, and it is read at CALL time -- so nothing observes it until
    # the first question is asked or the first child is spawned, which is why it
    # was dead in production for as long as it was. Every other spec in the suite
    # builds its own working thunk instead of taking this one, so the seam that
    # ships had no coverage at all. Asserted through the tools' own resolution
    # (#parent_timeline, Seam#parent), not by reaching for the lambda: what
    # matters is that the objects Wiring hands out can find the Agent, not how.
    it "hands its tools a parent handle that resolves to the live Agent" do
      agent = wire_agent
      expect(wiring.ask_human.send(:parent_timeline)).to equal(agent.timeline)
      expect(agent.toolset.fetch("subagent").seam.parent.call).to equal(agent.timeline)
    end

    # T10, at the construction site the card calls "the third, the one a human
    # actually reads". `Agent#occupancy` is asked with NO KEYWORD by
    # Frontend::PromptComposer::RunState, so the book has to have arrived when
    # the Agent was BUILT -- and this is the only place that happens.
    #
    # It is pinned here rather than by handing the same book to two objects and
    # comparing their arithmetic: that proves the division agrees and nothing
    # about the wiring. Deleting `context_window:` from AgentBuild#backing left
    # the whole suite green while a running chat printed 86% at the prompt and
    # published 0.216 to state.json -- the two-surfaces-disagreeing state the
    # card calls worse than being uniformly wrong. No book is injected here; the
    # provider is asked, exactly as production asks it.
    it "hands the built Agent the run's own book, so #occupancy needs no keyword" do
      recorder, session = wiring.run_state(nil)
      backend = offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 },
                                          mock: serving_provider)

      agent = wiring.wire_agent(channel:, recorder:, session:, backend:)
      agent.ask("ping")

      expect(agent.occupancy).to eq(7_079.fdiv(32_768))
      expect(agent.occupancy).not_to eq(7_079.fdiv(Lain::ContextWindow::CONSERVATIVE_FALLBACK))
    end

    it "exposes the reply seam and fleet supervisor it wired, as its own accessors" do
      wire_agent
      expect(wiring.ask_human).to be_a(Lain::Tools::AskHuman::Notifying)
      expect(wiring.questions).to be_a(Async::Queue)
      expect(wiring.supervisor).to be_a(Lain::Supervisor)
      expect(wiring.approvals).to be_a(Lain::Approval::Queue)
    end

    # T16: the session Toolset is built ONCE (toolset_build.rb:61-64) and the
    # Agent holds it in an ivar for its whole life. This identity is what made a
    # #to_schema memo PLAUSIBLE -- Context#render (context.rb:162) calls
    # `toolset.to_schema` unconditionally every turn, against the same instance.
    # T16 declined that memo on a measurement (~225us per call, orders of
    # magnitude under a round trip) plus an objection: extra reachable mutable
    # state on a value object CLAUDE.md says must be deeply frozen.
    #
    # T1 shipped the memo anyway, and both halves of T16's objection have since
    # been answered rather than overruled. Toolset now has value equality over
    # its canonical schema bytes, so it must hold a digest; the digest REQUIRES
    # the normalized schema, so keeping it is a reordering of work already done,
    # not an addition -- and it has to happen in #initialize, since the object
    # freezes itself there and a lazy memo would be a FrozenError. Nor is it
    # mutable state: what is stored is the same deeply-frozen structure
    # Canonical.normalize already returned, so the value stays deeply frozen.
    # Measured at review: ~844us once per session, ~461us saved every turn after
    # the first -- break-even at turn two. The invariant here -- one Toolset
    # survives the whole session -- is worth pinning on its own regardless
    # (Schneeman), and it is what makes the memo pay.
    it "renders every turn with the SAME Toolset instance across the session" do
      agent = wire_agent
      toolset_before = agent.toolset

      agent.ask("first turn")
      agent.ask("second turn")

      expect(agent.toolset).to equal(toolset_before)
    end

    # The chat's per-turn durability belt: {Lain::Middleware::JournalTurns} in
    # the turn phase, so every committed turn is on disk before the NEXT model
    # call. It reaches the Agent only through the run's one
    # {Lain::Agent::Instrumentation}, and T22's mutation run found that dropping
    # it there left this whole file green -- every other example builds over
    # Chronicle::Null, whose turn phase is empty either way, so "empty" proved
    # nothing. This one records.
    it "wires the chronicle's per-turn durability middleware, so each ask lands its turns on disk" do
      io = StringIO.new
      recording = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io:), journal_path: "wiring-spec.ndjson")
      recording_wiring = described_class.new(options: { grace: 5 }, chronicle: recording, status_feed:)
      recorder, session = recording_wiring.run_state(nil)
      agent = recording_wiring.wire_agent(channel:, recorder:, session:, backend:)

      agent.ask("ping")

      turns = io.string.each_line.map { |line| JSON.parse(line) }.select { |record| record["type"] == "turn" }
      # Two turns really landed (user + assistant), so the equality below is a
      # record agreeing with a conversation and not two empty lists agreeing.
      expect(turns.size).to eq(2)
      expect(turns.map { |record| record["digest"] }).to eq(agent.timeline.to_a.map(&:digest))
    end

    # T13: the run negotiates its Context's `#requires` against the provider it
    # actually talks to, under `:degrade`, and journals what it lost. Before
    # this, `Capability::Policy.for` had ZERO call sites in lib/, exe/ and bin/
    # -- the record type, the emitter and the {Lain::Bench::Session::Loader}
    # fold all existed and nothing ever constructed the policy, so twelve POC
    # journals carried no `capability_degraded` line while
    # {Lain::Context::CacheBreakpoints} required `:prompt_caching` from a
    # provider that does not offer it.
    #
    # Recorded here as well as in spec/lain/seams/capability_degraded_spec.rb
    # because THIS file is where #wire_agent's own contract lives: the mock
    # below declares a capability set that is missing one the real
    # {Lain::Context::REQUIRES} names, and the assertion reads the journal
    # bytes rather than a policy object nobody injected.
    it "journals what the run's provider cannot give its context, once, under :degrade" do
      io = StringIO.new
      recording = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io:), journal_path: "wiring-spec.ndjson")
      lacking = Lain::Provider::Mock.new(responses: [Lain::Response.new(content: [], stop_reason: :end_turn)],
                                         capabilities: Lain::Context::REQUIRES - %i[prompt_caching])
      recording_wiring = described_class.new(options: { grace: 5 }, chronicle: recording, status_feed:)
      recorder, session = recording_wiring.run_state(nil)
      recording_wiring.wire_agent(channel:, recorder:, session:,
                                  backend: offline_backend_class.new({ provider: "ollama", model: nil,
                                                                       max_tokens: 64 }, mock: lacking))

      degraded = io.string.each_line.map { |line| JSON.parse(line) }
                                    .select { |record| record["type"] == "capability_degraded" }
      expect(Lain::Context::REQUIRES).to include(:prompt_caching)
      expect(degraded.map { |record| record.values_at("capability", "provider") })
        .to eq([["prompt_caching", "Lain::Provider::Mock"]])
    end

    # The other arm, and the one that says the policy is resolving rather than
    # emitting unconditionally: the file's default mock declares the whole of
    # {Lain::Provider::CAPABILITIES}, so nothing its context requires is missing.
    it "journals no degradation when the provider supports everything the context requires" do
      io = StringIO.new
      recording = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io:), journal_path: "wiring-spec.ndjson")
      recording_wiring = described_class.new(options: { grace: 5 }, chronicle: recording, status_feed:)
      recorder, session = recording_wiring.run_state(nil)
      recording_wiring.wire_agent(channel:, recorder:, session:, backend:)

      expect(Lain::Context::REQUIRES.all? { |capability| mock_provider.supports?(capability) }).to be(true)
      expect(io.string).not_to include("capability_degraded")
    end

    # T12 AC1: no --auto-approve, no third surface -- unchanged wiring.
    it "wires no auto surface without --auto-approve" do
      wire_agent
      expect(wiring.auto_surface).to be_nil
    end

    # T12 AC1: --auto-approve constructs the surface over the SAME role_spawn
    # seam a `@role/skill` line folds through.
    it "wires an AutoSurface over its own role_spawn seam under --auto-approve" do
      wiring = described_class.new(options: { grace: 5, auto_approve: true }, chronicle:, status_feed:)
      recorder, session = wiring.run_state(nil)
      wiring.wire_agent(channel:, recorder:, session:, backend:)

      expect(wiring.auto_surface).to be_a(Lain::Approval::AutoSurface)
    end

    # T17 AC1: no --secret-oracle, no surface. Asserted at the CONSTRUCTION
    # site as well as at the fan-out, because "a flag that wires nothing" and
    # "a capability with no reachable construction" are the same defect read
    # from opposite ends, and this chunk produced both.
    it "wires no secret surface without --secret-oracle" do
      wire_agent
      expect(wiring.secret_surface).to be_nil
    end

    describe "--secret-oracle" do
      let(:wiring) { described_class.new(options: { grace: 5, secret_oracle: true }, chronicle:, status_feed:) }

      before do
        recorder, session = wiring.run_state(nil)
        wiring.wire_agent(channel:, recorder:, session:, backend:)
      end

      it "constructs the triage surface" do
        expect(wiring.secret_surface).to be_a(Lain::Approval::SecretSurface)
      end

      it "memoizes it, so the Repl and any later reader share one surface and one journal fd" do
        expect(wiring.secret_surface).to be(wiring.secret_surface)
      end

      # The whole point of the rung: even a run whose every provider knob names
      # a remote arm judges its parked secrets locally. Captured off the tier
      # the surface actually holds, not off a `.new` count.
      it "builds it against the LOCAL ollama provider, whatever --provider and --summarizer-provider say" do
        remote = { grace: 5, secret_oracle: true, provider: "anthropic", summarizer_provider: "anthropic" }
        built = described_class.new(options: remote, chronicle:, status_feed:)
        recorder, session = built.run_state(nil)
        built.wire_agent(channel:, recorder:, session:, backend:)

        tier = built.secret_surface.instance_variable_get(:@oracle)
        provider = tier.instance_variable_get(:@inner).instance_variable_get(:@provider)
        expect(provider).to be_a(Lain::Provider::Ollama)
      end
    end
  end

  # B1: the tool-phase guard was constructed bare (`RefuseSecretWrites.new`
  # with no `journal:`), so a live credential-shaped refusal journaled to
  # `Channel::Null` and left no record while every other mount of this
  # middleware (consolidation.rb, improve.rb, run_recorder.rb) passes one.
  describe "the secret-write guard's journal wiring" do
    def credential_tool_use
      { "type" => "tool_use", "id" => "tu_1", "name" => "memory_write",
        "input" => { "id" => "creds", "description" => "oops", "body" => "sk-#{"a" * 20}" } }
    end

    let(:credential_provider) do
      Lain::Provider::Mock.new(responses: [
                                 Lain::Response.new(content: [credential_tool_use], stop_reason: :tool_use),
                                 Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                    stop_reason: :end_turn)
                               ])
    end
    let(:backend) do
      offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: credential_provider)
    end

    def build_agent_and_recorder
      recorder, session = wiring.run_state(nil)
      [wiring.wire_agent(channel:, recorder:, session:, backend:), recorder]
    end

    context "when the wired chat journal is capturing" do
      let(:journal) { RecordingChannel.new }
      # journal_path: a bogus-but-harmless NDJSON name -- Chronicle#spool
      # derives the WAL path from it via pure string manipulation
      # (Paths.wal_for) and ResponseWal opens its file lazily on the first
      # frame, which a Provider::Mock-backed run never writes.
      let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "b1-spec-fake-session.ndjson") }

      it "records a WriteRefused naming the matched pattern when a credential-shaped memory_write is refused" do
        agent, = build_agent_and_recorder
        agent.ask("please remember this credential")

        refusal = journal.events.find { |event| event.is_a?(Lain::Telemetry::WriteRefused) }
        expect(refusal).not_to be_nil
        expect(refusal.pattern).to eq("openai-style api key")
      end
    end

    context "when the chat started with --no-journal" do
      let(:chronicle) { Lain::CLI::Chronicle::Null.new }

      it "still refuses a credential-shaped memory_write, and nothing raises" do
        agent, recorder = build_agent_and_recorder

        expect { agent.ask("please remember this credential") }.not_to raise_error
        expect { recorder.fetch("creds") }.to raise_error(Lain::Memory::Index::UnknownId)
      end
    end
  end

  # B4: the guard's `oracle:` seam sat on its NullOracle in the live chat, so
  # the memory-save gate judged nothing there. Wiring it in composes the two
  # findings B2 separated: a credential is a PATTERN hit, a contentless save is
  # the oracle's DECLINE, and they must stay distinguishable in the journal.
  describe "the secret-write guard's oracle wiring" do
    let(:journal) { RecordingChannel.new }
    # See B1's note above on journal_path: pure string manipulation derives the
    # WAL path, and a Provider::Mock run never writes a frame.
    let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "b4-spec-fake-session.ndjson") }
    let(:backend) do
      offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: dispatching_provider)
    end
    let(:dispatching_provider) do
      Lain::Provider::Mock.new(responses: [
                                 Lain::Response.new(content: [tool_use], stop_reason: :tool_use),
                                 Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                    stop_reason: :end_turn)
                               ])
    end

    def dispatch
      recorder, session = wiring.run_state(nil)
      agent = wiring.wire_agent(channel:, recorder:, session:, backend:)
      agent.ask("do the thing")
      [agent, recorder]
    end

    def refusals = journal.events.grep(Lain::Telemetry::WriteRefused)

    # The dispatched tool's own answer, read back off the committed timeline --
    # the only place a middleware-withheld call and a downstream one can be told
    # apart without reaching inside the stack.
    def tool_results(agent)
      agent.timeline.to_a.map(&:content).grep(Array).flatten.grep(Hash)
           .select { |block| block["type"] == "tool_result" }.map { |block| block["content"] }.join("\n")
    end

    context "with a memory_write whose body is a git commit SHA" do
      let(:sha) { "9a1b2c3d4e5f60718293a4b5c6d7e8f901234567" }
      let(:tool_use) do
        { "type" => "tool_use", "id" => "tu_1", "name" => "memory_write",
          "input" => { "id" => "head-sha", "description" => "the commit under test", "body" => sha } }
      end

      it "is not refused, and the item lands in the recorder" do
        _agent, recorder = dispatch

        expect(refusals).to be_empty
        expect(recorder.fetch("head-sha").body).to eq(sha)
      end
    end

    context "with a memory_write carrying an API-key-shaped body" do
      let(:tool_use) do
        { "type" => "tool_use", "id" => "tu_1", "name" => "memory_write",
          "input" => { "id" => "creds", "description" => "oops", "body" => "sk-#{"a" * 20}" } }
      end

      it "is refused under the pattern's name, never as the oracle's decline" do
        _agent, recorder = dispatch

        expect(refusals.map(&:pattern)).to eq(["openai-style api key"])
        expect(Lain::Middleware::RefuseSecretWrites.decline?(refusals.first.pattern)).to be(false)
        expect { recorder.fetch("creds") }.to raise_error(Lain::Memory::Index::UnknownId)
      end
    end

    context "with a memory_write whose body is blank" do
      let(:tool_use) do
        { "type" => "tool_use", "id" => "tu_1", "name" => "memory_write",
          "input" => { "id" => "nothing", "description" => "empty", "body" => "  \n\t " } }
      end

      it "is refused as the oracle's decline, under no pattern name" do
        agent, recorder = dispatch

        expect(refusals.map(&:pattern)).to eq([Lain::Middleware::RefuseSecretWrites::ORACLE_DECLINE])
        expect(Lain::Middleware::RefuseSecretWrites.decline?(refusals.first.pattern)).to be(true)
        expect(Lain::Middleware::RefuseSecretWrites::PATTERNS).not_to have_key(refusals.first.pattern)
        expect { recorder.fetch("nothing") }.to raise_error(Lain::Memory::Index::UnknownId)
        # B2's model-facing half: a decline must make no credential claim.
        expect(tool_results(agent)).to include("not worth writing")
        expect(tool_results(agent)).not_to include("pattern")
      end
    end

    # GUARDED_TOOLS holds improvement_write too, and its input is
    # {note, kind, evidence_digests} -- no `body`. The gate abstains there
    # (MemorySave::Gate::JUDGED_FIELD), and if it ever stops abstaining this
    # wiring refuses EVERY improvement note. The chat toolset does not carry the
    # tool, so reaching Handler::Live's unknown-tool answer is the proof the
    # guard let it through rather than withholding it.
    context "with an improvement_write, which carries no body for the gate to judge" do
      let(:tool_use) do
        { "type" => "tool_use", "id" => "tu_1", "name" => "improvement_write",
          "input" => { "note" => "the guard should not judge this", "kind" => "insight",
                       "evidence_digests" => [] } }
      end

      it "reaches downstream rather than being declined" do
        agent, = dispatch

        expect(refusals).to be_empty
        expect(tool_results(agent)).to include('no tool named "improvement_write"')
      end
    end
  end

  # T1: a streamed tool's bytes are a VIEW, not a record. Wiring hands
  # Handler::Live a fan-out over the run's TTY Channel AND the editor's, so
  # nvim's lain://journal sees what the terminal sees -- while the durable
  # NDJSON keeps only the turn's tool_result (Tools::Bash.render_output),
  # which is where those same bytes already are.
  describe "streamed tool output on the live views" do
    let(:bash_use) do
      { "type" => "tool_use", "id" => "tu_bash", "name" => "bash", "input" => { "command" => "printf hello" } }
    end
    let(:streaming_provider) do
      Lain::Provider::Mock.new(responses: [
                                 Lain::Response.new(content: [bash_use], stop_reason: :tool_use),
                                 Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                    stop_reason: :end_turn)
                               ])
    end
    let(:backend) do
      offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: streaming_provider)
    end
    # The TTY leg, recorded rather than a real SizedQueue: nothing drains it here.
    let(:channel) { RecordingChannel.new }
    let(:view_channel) { Lain::Channel::DropOldest.new }
    let(:journal) { RecordingChannel.new }
    # See B1's note on journal_path: Chronicle#spool derives the WAL path by
    # pure string manipulation, and a Provider::Mock run never writes a frame.
    let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "t1-spec-fake-session.ndjson") }
    let(:views) { { channel: view_channel, socket_path: "/tmp/lain-t1-spec.sock", journal: } }
    # --yolo, because bash is tier 3 and would otherwise park on the approval
    # gate; this block is about where the bytes go, not who let them run.
    let(:wiring) { described_class.new(options: { grace: 5, yolo: true }, chronicle:, status_feed:) }

    def dispatch(attached)
      recorder, session = wiring.run_state(nil)
      agent = wiring.wire_agent(channel:, recorder:, session:, backend:, views: attached)
      agent.ask("run it")
      agent
    end

    def streamed(events) = events.grep(Lain::Telemetry::ToolOutput)

    # The tool's own answer off the committed timeline -- proof the call
    # completed rather than dying inside the fan-out.
    def tool_results(agent)
      agent.timeline.to_a.map(&:content).grep(Array).flatten.grep(Hash)
           .select { |block| block["type"] == "tool_result" }.map { |block| block["content"] }.join("\n")
    end

    it "fans a bash tool's stdout onto the editor's Channel as well as the TTY's" do
      dispatch(views)

      expect(streamed(channel.events).map(&:bytes).join).to include("hello")
      expect(streamed(view_channel.drain).map { |event| [event.tool_use_id, event.stream, event.bytes] })
        .to eq([["tu_bash", :stdout, "hello"]])
    end

    it "keeps the streamed bytes off the durable record, which already carries them in the tool_result" do
      agent = dispatch(views)

      expect(streamed(journal.events)).to be_empty
      expect(tool_results(agent)).to include("hello")
    end

    it "completes the tool, and still renders to the TTY, when the editor quit and closed its Channel" do
      view_channel.close
      agent = dispatch(views)

      expect(streamed(channel.events).map(&:bytes).join).to include("hello")
      expect(tool_results(agent)).to include("hello")
    end

    it "renders to the TTY and raises nothing when no editor is attached" do
      agent = dispatch(nil)

      expect(streamed(channel.events).map(&:bytes).join).to include("hello")
      expect(tool_results(agent)).to include("hello")
    end
  end

  # A8: the assembly, and the point the whole chunk converges on. A plain `lain
  # chat` compacts, which means the Agent gets three things Wiring never passed
  # before: the run's per-turn Context source, the eager-summary observer its
  # ToolRunner fires through, and a journal that TEES turn_usage to that source
  # -- `context_for`'s `usage:` is A2's Integer, while {Lain::Compaction::Cold}
  # needs a {Lain::Telemetry::TurnUsage}'s cache-read count and the render seam
  # has no route to it.
  describe "the compaction mount" do
    require "tmpdir"

    let(:summary_text) { "EAGER-SUMMARY-OF-THE-BIG-RESULT" }
    let(:big_file) { File.join(@dir, "big.txt") }

    # Only the two network edges are doubled: the chat provider and the eager
    # tier. The Eager itself, the observer, the snapshot, the scheduler and the
    # render are the real wiring under test.
    let(:summarizing_backend_class) do
      Class.new(Lain::CLI::Backend) do
        def initialize(options, mock:, oracle:)
          super(options)
          @mock = mock
          @oracle = oracle
        end

        def provider(**) = @mock

        def eager = @eager ||= Lain::Oracle::Eager.new(oracle: @oracle)
      end
    end

    let(:reading_provider) do
      Lain::Provider::Mock.new(responses: [
                                 Lain::Response.new(content: [read_use], stop_reason: :tool_use),
                                 Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                    stop_reason: :end_turn)
                               ])
    end

    let(:read_use) do
      { "type" => "tool_use", "id" => "tu_1", "name" => "read_file", "input" => { "path" => big_file } }
    end

    # compact_keep 1 + compact_bytes 1 puts every turn past the byte threshold,
    # so what decides is TIMING -- and Provider::Mock's NO_CACHING profile makes
    # the first turn_usage confirm the cache cold, which is only true if the
    # source is actually on the journal's sink list.
    let(:compaction_options) { { provider: "ollama", model: nil, max_tokens: 64, compact_keep: 1, compact_bytes: 1 } }

    let(:backend) do
      summarizing_backend_class.new(compaction_options, mock: reading_provider,
                                                        oracle: WiringSpecSummarizer.new(summary_text))
    end

    let(:journal) { RecordingChannel.new }
    let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "a8-spec-fake-session.ndjson") }

    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        File.write(File.join(dir, "big.txt"), "the quick brown fox jumped over the lazy dog. " * 140)
        example.run
      end
    end

    # A bounded spin, never a synchronization: the fire resolves on its own
    # fiber and the timeout turns "it never did" into a report instead of a hang.
    def settle(task, eager, digest)
      task.with_timeout(1) { task.sleep(0.001) while eager.held(digest).nil? }
    end

    # Read off the Agent rather than re-asked of the Backend: `#pipeline_source`
    # binds its journal on the FIRST call and now refuses a differing second
    # one, so a spec that re-asked with different arguments would be exercising
    # a wiring the run never performs. Through the Agent's one
    # {Lain::Agent::Instrumentation} since T22 -- `fetch`, not `dig`, so a
    # renamed ivar is a KeyError here and never a silent nil.
    def source_of(agent) = instrumentation_of(agent).pipeline_source

    def instrumentation_of(agent)
      agent.instance_variables.include?(:@instrumentation) or
        raise KeyError, "the Agent no longer carries @instrumentation: this seam needs updating"

      agent.instance_variable_get(:@instrumentation)
    end

    def decisions = journal.events.grep(Lain::Compaction::Source::CompactionDecision)

    # Two asks, because the head a compaction can profitably drop only exists
    # once the first turn's big tool_result is behind the trailing window: the
    # opening exchange alone is small enough that Source#shrinks? refuses the
    # rewrite. The settle between them is what makes the eager fire observable.
    def converse(agent)
      Sync do |task|
        agent.ask("read it")
        settle(task, backend.eager, Lain::Canonical.digest(File.read(big_file)))
        agent.ask("now summarize what you saw")
      end
    end

    # ONE Eager, reached from both ends: the observer fires into it and the
    # source snapshots it. Two instances would mean every fire landed somewhere
    # no render reads, with `hits` reporting an honest, useless zero.
    it "hands the Agent the run's ONE source and its ONE summary observer" do
      agent = wire_agent

      expect(source_of(agent)).to be_a(Lain::Compaction::Source)
      expect(agent.instance_variable_get(:@tool_runner).instance_variable_get(:@observer)).to be(backend.tool_observer)
      expect(backend.tool_observer.eager).to be(backend.eager)
      expect(source_of(agent).eager).to be(backend.eager)
    end

    # Without the tee `Cold` is never fed, the `:cold` decision path is dead on
    # the live path, and every compaction journals `cache_state: forced` -- a
    # bench arm that measures nothing.
    it "tees turn_usage to the source, so a zero cache-read confirms the cache cold" do
      agent = wire_agent
      cold = source_of(agent).instance_variable_get(:@cold)
      expect(cold).not_to be_cold

      Sync { agent.ask("read it") }

      expect(cold).to be_cold
      # Provider::Mock carries NO_CACHING, so there is no TTL for an idle mark
      # to compare against and each zero cache-read confirms on its own -- one
      # per model round trip, and a tool-use turn makes two.
      confirmations = journal.events.grep(Lain::Compaction::Cold::CacheColdConfirmed)
      expect(confirmations.map(&:reason).uniq).to eq([:signal_only])
    end

    # The live chat Context is deliberately NOT Ractor-shareable -- /model's
    # slot is mutable by design (model_switch.rb:20-22) -- so the composed
    # per-turn pipeline has to be built from a flattened twin. Without that,
    # EVERY compacting turn of every real chat raises Ractor::IsolationError out
    # of Scheduler::COMPOSE, and no spec holding a plain Context can see it.
    it "compacts a Context carrying the live /model slot, which is not shareable" do
      agent = wire_agent
      expect(agent.context).not_to be_deeply_frozen

      expect { converse(agent) }.not_to raise_error

      expect(decisions.map(&:compacted)).to include(true)
    end

    # AC3, end to end: the tool result crosses Summarizing's threshold, the
    # post-dispatch observer fires a summary into the run's Eager, and the next
    # render -- which compacts, because the cache is cold -- carries the FIRED
    # TEXT where an unwired run would carry an elision line.
    it "renders the summary a tool dispatch fired, not an elision line" do
      converse(wire_agent)

      rendered = Lain::Canonical.dump(reading_provider.last_request.messages)

      expect(rendered).to include(summary_text)
      # The dropped bytes are really gone -- the summary replaced them rather
      # than riding alongside. (The turn's other blocks -- a plain text turn, a
      # tool_use -- still carry ELIDED lines: nothing is summarizable there, and
      # attesting them is the invariant, not a miss.)
      expect(rendered).not_to include("the quick brown fox jumped over the lazy dog. " * 5)
      expect(decisions.map(&:compacted)).to include(true)
      expect(decisions.map(&:summary_hits).max).to be >= 1
    end

    # The live half of the review's cost-honesty fix. This run's model is
    # Ollama's local default, which Backend::COMPACTION_PRICES prices at zero
    # -- so the accounting reads "$0.0", and WITHOUT the model beside it that
    # is indistinguishable on the record from a compaction that genuinely cost
    # nothing. It is also what a reader needs to spot a `/model` switch: this
    # names the tier the estimate was priced against, TurnUsage names the tier
    # that answered, and after a switch they differ.
    it "journals the model its zero cost figures are quoted in" do
      converse(wire_agent)

      accounting = journal.events.grep(Lain::Telemetry::Compaction)
      expect(accounting).not_to be_empty
      expect(accounting.map(&:model).uniq).to eq([Lain::Provider::Ollama::DEFAULT_MODEL])
      expect(accounting.map(&:cost_saved).uniq).to eq(["0.0"])
    end

    context "with --no-compact" do
      let(:compaction_options) { super().merge(compact: false) }

      it "leaves the Agent on the Null source, rendering exactly as an unwired chat would" do
        agent = wire_agent

        Sync { agent.ask("read it") }

        expect(source_of(agent)).to be(Lain::Agent::PipelineSource::Null)
        expect(Lain::Canonical.dump(reading_provider.last_request.messages)).not_to include(summary_text)
        expect(decisions).to be_empty
      end
    end
  end

  # D2: `--isolation`, wired at the ONE seam the fleet leases through. The main
  # chat is deliberately NOT leased -- #run_state builds its Session on
  # {Lain::WorkerEnv.default}, because the user's own edits belong in the user's
  # own tree -- so what a leased environment reaches is an ACTOR-mode subagent,
  # adopted through this Supervisor.
  describe "the fleet's isolation backend" do
    require "fileutils"
    require "mixlib/shellout"
    require "tmpdir"

    # The journal Wiring hands the Supervisor is the run's live Channel; a
    # recording stand-in is what lets the lease records be read back (and never
    # blocks, unlike a SizedQueue nobody drains).
    let(:channel) { RecordingChannel.new }

    def wiring_with(isolation)
      described_class.new(options: { grace: 5, isolation: }, chronicle:, status_feed:)
    end

    # Adoption is what leases: the Supervisor acquires the worker's environment
    # and hands it to the launch block, exactly as {Lain::Tools::Subagent}'s
    # `mode: :actor` dispatch does. The supervisor's own reactor task is what an
    # actor outlives, so the adoption runs under a Sync the spec holds.
    def adopt_worker(wiring)
      recorder, session = wiring.run_state(nil)
      wiring.wire_agent(channel:, recorder:, session:, backend:)
      Sync do |task|
        wiring.supervisor.run(task)
        wiring.supervisor.adopt(role: "researcher") { |worker_env| WiringSpecWorker.new(worker_env) }
      ensure
        wiring.supervisor.stop
      end
    end

    def leases = channel.events.grep(Lain::Telemetry::IsolationLease)

    # A chat started somewhere OTHER than the repo this suite runs in, so "the
    # lease names the chat's own cwd" is an assertion and not a coincidence --
    # and so no `.lain/services.rb` of the host project can decorate the backend.
    def in_throwaway_chat_dir(&block)
      Dir.mktmpdir("lain-d2-chat") { |dir| Dir.chdir(File.realpath(dir), &block) }
    end

    context "without an isolation option" do
      it "leases the chat's own process environment -- the shared-process default" do
        chat_cwd = nil
        worker = in_throwaway_chat_dir do |dir|
          chat_cwd = dir
          adopt_worker(wiring_with(nil))
        end

        expect(worker.session.worker_env.cwd).to eq(chat_cwd)
        expect(worker.session.worker_env.env).to eq(ENV.to_h)
      end

      # The resolver decorates BY NEED, so a run whose journal records anything
      # never holds a bare Null -- what a spec can see is the concrete backend
      # NAMED on the lease record the Journal decorator emits.
      it "resolves the shared-process backend, journalled, so the lease is on the record" do
        in_throwaway_chat_dir { adopt_worker(wiring_with(nil)) }

        expect(leases.map { |lease| [lease.kind, lease.backend] })
          .to eq([[:acquired, "Lain::Isolation::Null"], [:released, "Lain::Isolation::Null"]])
      end
    end

    context "with the worktree isolation option" do
      # The spec's own git calls reuse the backend's pinned scrub set, so the
      # throwaway repo is built hermetically under a GIT_*-polluted env (a
      # pre-commit hook) exactly as the backend runs.
      def run_git(dir, *args)
        Mixlib::ShellOut.new("git", "-C", dir, *args,
                             environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command.error!
      end

      # Copied, not rebuilt: five git subprocesses per example for a directory that
      # is identical every time (see {SeedRepo}). A method, not a constant --
      # a constant inside a top-level `RSpec.describe do ... end` lands on Object,
      # where a second spec file spelling the same name silently clobbers it.
      def seed_repo(dir) = FileUtils.cp_r("#{SeedRepo.at(seed_files)}/.", dir)

      def seed_files = { "README" => "seed\n" }

      # A throwaway repo AND a throwaway XDG_RUNTIME_DIR: the leased checkouts
      # land under the tmpdir, never the machine's real runtime dir and never the
      # lain repo this suite runs in.
      def in_throwaway_repo
        Dir.mktmpdir("lain-d2-project") do |project|
          Dir.mktmpdir("lain-d2-runtime") do |runtime|
            repo = File.realpath(project)
            seed_repo(repo)
            Dir.chdir(repo) { with_env("XDG_RUNTIME_DIR" => File.realpath(runtime)) { yield repo } }
          end
        end
      end

      it "hands the supervisor the resolved worktree backend" do
        in_throwaway_repo { adopt_worker(wiring_with("worktree")) }

        expect(leases.map(&:backend).uniq).to eq(["Lain::Isolation::Worktree"])
      end

      it "runs the adopted actor's session against the leased checkout, not the chat's cwd" do
        chat_cwd = nil
        worker = in_throwaway_repo do |repo|
          chat_cwd = repo
          adopt_worker(wiring_with("worktree"))
        end
        leased = worker.session.worker_env.cwd

        expect(leased).not_to eq(chat_cwd)
        # A REAL checkout, not a path the lease merely named: it exists, git
        # knows it (`.git` is a file inside a linked worktree), and it carries
        # the repo's seeded content -- so the cwd below is somewhere a child's
        # tools can actually work, which `#resolve`'s string math cannot show.
        expect(worker.checkout).to eq({ exists: true, repo: true, seeded: true })
        expect(worker.session.worker_env.resolve("notes.md")).to eq(File.join(leased, "notes.md"))
      end
    end

    # Resolved BEFORE {Lain::CLI::Chronicle#start} pins the header, so the
    # refusal lands while the session record is still empty -- the same
    # refusal-before-journal ordering --resume and --fork already keep.
    context "with an unrecognized isolation option" do
      it "raises a Lain::Error and leaves no session record behind" do
        Dir.mktmpdir("lain-d2-state") do |state|
          paths = Lain::Paths.new(env: { "HOME" => "/home/nobody", "XDG_STATE_HOME" => state })
          journaled = Lain::CLI::Chronicle.for(enabled: true, paths:)
          wiring = described_class.new(options: { grace: 5, isolation: "docker" }, chronicle: journaled, status_feed:)
          recorder, session = wiring.run_state(nil)

          expect { wiring.wire_agent(channel:, recorder:, session:, backend:) }
            .to raise_error(Lain::Error, /unknown isolation backend "docker".*none.*worktree/m)

          journaled.close(reason: :exit)
          # T3: "no session record behind" is now literal. A journal that
          # closes with nothing ever recorded into it removes its own file, so
          # the zero-byte artifact never reaches the readers that pick the
          # newest session (--resume, --fork, watch, sessions).
          expect(File).not_to exist(journaled.journal_path)
        end
      end
    end
  end

  describe "#run" do
    require "stringio"
    require "tmpdir"

    # The T9 injection seams: a spec assembles and runs the whole conversation
    # through #run's own path -- no send(:build_repl), no instance_variable_set
    # -- by handing in a StringIO-backed TTY factory and a recording conductor
    # opener instead of the real-terminal defaults.
    let(:opened) { [] }
    let(:conductor_opener) { ->(**kwargs) { Lain::CLI::Conductor.open(**kwargs).tap { |c| opened << c } } }

    # T13 hands the factory a `prompt_renderer:` too. It is swallowed rather
    # than forwarded: what this spec is about is the object WIRING composes and
    # passes on, not what the TTY then does with it (that is tty_spec's).
    def tty_factory(input, dir)
      lambda do |channel:, **|
        Lain::Frontend::TTY.new(channel:, output: StringIO.new, input: StringIO.new(input),
                                history_path: File.join(dir, "history"))
      end
    end

    def run_wiring(input: "quit\n", options: { grace: 5 })
      Dir.mktmpdir do |dir|
        wiring = described_class.new(options:, chronicle:, status_feed:,
                                     tty_factory: tty_factory(input, dir), conductor_opener:)
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
        wiring
      end
    end

    it "threads the injected tty/conductor seams -- the conductor the opener built is the one exposed" do
      wiring = run_wiring

      expect(opened).to eq([wiring.conductor])
    end

    # T7: the Conductor is the ONE place a user prompt is answered, so it is
    # where RunClock#record_input is called -- and the clock it records on has
    # to be the one the StatusFeed publishes, or the published idle never
    # resets. ChatLaunch builds it; this class only has to pass it on.
    it "passes the run's RunClock on to the conductor it opens" do
      run_clock = Lain::RunClock.new
      seen = []
      opener = ->(**kwargs) { Lain::CLI::Conductor.open(**kwargs).tap { seen << kwargs[:run_clock] } }

      Dir.mktmpdir do |dir|
        wiring = described_class.new(options: { grace: 5 }, chronicle:, status_feed:, run_clock:,
                                     tty_factory: tty_factory("quit\n", dir), conductor_opener: opener)
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
      end

      expect(seen).to eq([run_clock])
    end

    # {Lain::CLI::Wiring#goal_journal} (wiring.rb:334) resolves the standing-goal
    # driver's destination through {Lain::CLI::Chronicle#record_journal}. Nothing
    # asserted it: replacing the resolution with a fresh /dev/null Journal left
    # the ENTIRE suite green (T22's M26), because every other example here runs
    # over Chronicle::Null, whose record_journal IS a discard -- so a discard
    # substituted for a discard changed nothing observable anywhere. This one
    # records, and drives the real driver the run wired.
    context "with a recording chronicle" do
      let(:journal_io) { StringIO.new }
      let(:chronicle) do
        Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io),
                                 journal_path: "wiring-spec-goal.ndjson")
      end

      def settled_with(text)
        Lain::Timeline.empty.commit(role: :user, content: [{ "type" => "text", "text" => "go" }])
                      .commit(role: :assistant, content: [{ "type" => "text", "text" => text }])
      end

      # `run_wiring` inlined for one reason: it closes the conductor, and
      # {Lain::CLI::Conductor#close} closes the session record. The driver has to
      # write while the record is still open, so the close moves BELOW the drive.
      it "wires the standing-goal driver over the run's own journal, not a discard" do
        Dir.mktmpdir do |dir|
          wiring = described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                                       tty_factory: tty_factory("quit\n", dir), conductor_opener:)
          wiring.run(backend:, resumed: nil, nvim: nil)

          driver = wiring.command_surface.goal_driver
          driver.start("ship it")
          driver.poll(settled_with("working on it"))
          wiring.conductor.close(reason: :exit)
        end

        records = journal_io.string.each_line.map { |line| JSON.parse(line) }
        # The run really opened a record, so the selection below is a search
        # through a populated file rather than two empty lists agreeing.
        expect(records.map { |record| record["type"] }).to include("session")
        expect(records.select { |record| record["type"] == "goal_iteration" }.map { |record| record["goal"] })
          .to eq(["ship it"])
      end
    end

    it "assembles the frozen Command::Env once, nil-free, from the collaborators it wired" do
      wiring = run_wiring
      env = wiring.command_env

      expect(env).to be_frozen
      expect(env.sessions).to be_a(Lain::CLI::Sessions)
      expect(env.tmux_surface).to be_a(Lain::CLI::TmuxSurface)
      expect(env.approvals).to be(wiring.approvals)
      expect(env.supervisor).to be(wiring.supervisor)
      expect(env.replies).to be_a(Lain::CLI::HumanReplies)
      expect(env.agent).to be_a(Lain::Agent)
      expect(env.status).to be(status_feed)
      expect(env.fork_point).to be_a(Lain::CLI::ForkPoint)
      expect(env.chronicle).to be(chronicle)
    end

    # The load-bearing identity AC1/AC3 stand on (T14 panel probe 7): a dropped
    # surface_kwargs would leave these readers on their Nulls and silently
    # disconnect /yolo from the Gate and /model from the Agent's Context.
    it "hands the Env the SAME switches the Gate and the Agent's context hold" do
      wiring = run_wiring
      env = wiring.command_env

      expect(env.policy_switch).to be_a(Lain::Approval::PolicySwitch)
      # T21: what the Gate holds is the LADDER, and the identity that matters is
      # one rung down -- its asking rung must park on the session's ONE queue,
      # the same object /approve drains.
      expect(env.policy_switch.current).to be_a(Lain::Approval::Escalation)
      expect(env.policy_switch.current.find { |rung| rung.name == "surfaces" }.queue).to be(wiring.approvals)

      expect(env.model_switch).to be_a(Lain::Context::ModelSwitch)
      expect(env.agent.context.model).to eq(env.model_switch.current)
      env.model_switch.switch("probe-model-x", surface: "probe")
      expect(env.agent.context.model).to eq("probe-model-x")
    end

    # T15: BEFORE this card a wired session read the project tree FIVE times --
    # two Skill::Catalog loads (the command Surface's, and the one
    # ReplMiddleware.renderer did for Tools::RunSkill) and three Prompt::Slots
    # loads (Backend's memoized one, the repl stack's, and RunSkill's). Same
    # tree, so the drift never showed in a test; it would show the moment a
    # `.lain/` file changed mid-session, and it defeats the "session-fixed
    # snapshot" claim both objects are documented with. One load each, threaded.
    describe "the session's ONE catalog and ONE slots" do
      def help_catalog(surface)
        surface.commands.registry.find { |command| command.name == "help" }.instance_variable_get(:@catalog)
      end

      def run_skill_renderer(wiring)
        wiring.command_env.agent.toolset.fetch("run_skill").instance_variable_get(:@renderer)
      end

      def stack_renderer(surface)
        surface.middleware.to_a.first.instance_variable_get(:@renderer)
      end

      it "hands /help, the repl stack, and Tools::RunSkill the SAME Skill::Catalog" do
        wiring = run_wiring
        surface = wiring.command_surface
        catalog = help_catalog(surface)

        expect(catalog).to be_a(Lain::Skill::Catalog)
        expect(stack_renderer(surface).instance_variable_get(:@catalog)).to be(catalog)
        expect(run_skill_renderer(wiring).instance_variable_get(:@catalog)).to be(catalog)
      end

      it "hands Backend#context, RoleSpawn, and Tools::RunSkill the SAME Prompt::Slots" do
        wiring = run_wiring
        slots = backend.slots

        expect(slots).to be_a(Lain::Prompt::Slots)
        expect(wiring.role_spawn.instance_variable_get(:@slots)).to be(slots)
        expect(run_skill_renderer(wiring).instance_variable_get(:@slots)).to be(slots)
        expect(stack_renderer(wiring.command_surface).instance_variable_get(:@slots)).to be(slots)
      end

      # T40: the pair had TWO owners -- Wiring loaded the catalog, Backend the
      # slots -- and travelled onward as two keywords, which is the state of an
      # object nobody had named. It is one {Skill::Library} now, owned by the
      # Backend (the lowest point above every reader, since #context renders the
      # slots into the system prompt). Both halves of the run therefore come out
      # of the SAME library instance, not merely out of equal snapshots.
      it "reads both halves out of the Backend's ONE library" do
        wiring = run_wiring
        library = backend.library

        expect(help_catalog(wiring.command_surface)).to be(library.catalog)
        expect(wiring.role_spawn.instance_variable_get(:@slots)).to be(library.slots)
        expect(run_skill_renderer(wiring).instance_variable_get(:@catalog)).to be(library.catalog)
      end

      # What the threading BUYS, stated as a count rather than as identity: five
      # reads of the project tree before T15, two after it (one per owner), and
      # one apiece now. Identity alone would still pass if some reader loaded a
      # snapshot it then threw away, so the count is its own assertion.
      it "loads the catalog exactly once and the slots exactly once for the whole session" do
        allow(Lain::Skill::Catalog).to receive(:load).and_call_original
        allow(Lain::Prompt::Slots).to receive(:load).and_call_original

        run_wiring

        expect(Lain::Skill::Catalog).to have_received(:load).once
        expect(Lain::Prompt::Slots).to have_received(:load).once
      end
    end

    it "wires the queue-shaped YoloApprovals under --yolo, so the env reader stays nil-free" do
      wiring = run_wiring(options: { grace: 5, yolo: true })

      expect(wiring.command_env.approvals).to be(Lain::CLI::Command::Env::YoloApprovals)
    end

    # T13: this class is the only object holding the Agent, the RunClock and
    # the StatusFeed at once, so composing the prompt's state reader is its
    # job -- and the TTY factory is where it hands it over.
    describe "the prompt renderer" do
      require "fileutils"

      let(:plain_theme) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false)) }

      # The fleet reading the renderer takes off the feed. Stubbed here and
      # nowhere else, because this is the only block that actually composes a
      # prompt -- every other #run spec leaves the renderer unused.
      before { allow(status_feed).to receive(:state).and_return({ "fleet" => [] }) }

      # Records what #run passed, and still builds a working TTY so the rest
      # of the run proceeds exactly as the specs above drive it.
      def recording_factory(input, dir, seen)
        lambda do |channel:, **kwargs|
          seen << kwargs[:prompt_renderer]
          tty_factory(input, dir).call(channel:)
        end
      end

      def run_recording(options: { grace: 5 }, &notice)
        seen = []
        Dir.mktmpdir do |dir|
          wiring = described_class.new(options:, chronicle:, status_feed:,
                                       tty_factory: recording_factory("quit\n", dir, seen), conductor_opener:)
          wiring.run(backend:, resumed: nil, nvim: nil, &notice)
          wiring.conductor.close(reason: :exit)
        end
        seen
      end

      it "hands the TTY factory a renderer composed from the run's own state" do
        expect(run_recording.first).to be_a(Lain::Frontend::PromptComposer::Formatted)
      end

      # AC1, through the wiring rather than in isolation: the renderer this
      # class built reads the LIVE agent, so the model it names is the one the
      # run is actually talking to.
      it "builds it over the live model slot, the run clock and the status feed" do
        composed = run_recording.first.call(text: "> ", theme: plain_theme)

        expect(composed).to include(Lain::Provider::Ollama::DEFAULT_MODEL)
        expect(composed.lines.last).to eq("> ")
      end

      # AC3: a project config that does not parse is reported through the same
      # startup-notice seam a resumed chat's notices use, and the chat is still
      # usable -- today's prompt, not a crash.
      def with_project_config(bytes)
        notices = []
        renderer = Dir.mktmpdir do |project|
          FileUtils.mkdir_p(File.join(project, ".lain"))
          File.binwrite(File.join(project, ".lain", "prompt.toml"), bytes)
          Dir.chdir(project) { run_recording { |notice| notices << notice }.first }
        end
        [notices, renderer]
      end

      it "reports a malformed project config as a startup notice, and keeps the chat usable" do
        notices, renderer = with_project_config(%(format = "[unclosed"\n))

        expect(notices.join).to include("prompt.toml")
        expect(renderer).to be_a(Lain::Frontend::PromptComposer::Null)
      end

      # `Wiring#run` has no rescue around the renderer and `exe/lain` catches
      # only Lain::Error, so an EncodingError escaping `.renderer` aborts the
      # chat with a backtrace before a prompt ever exists. A single Latin-1
      # byte in a project config is enough to do it.
      it "survives a project config that is not valid UTF-8, rather than aborting the chat" do
        notices = renderer = nil

        expect { notices, renderer = with_project_config(%(format = "\xBB "\n).b) }.not_to raise_error
        expect(notices.join).to include("prompt.toml")
        expect(renderer).to be_a(Lain::Frontend::PromptComposer::Null)
      end
    end

    # T27: request_review is a capability, so it is the toolset build's to
    # append -- but WHICH epic a chat is in is a question the chat tier never
    # had to answer before, and the answer decides whether the tool exists at
    # all. {EpicMount} owns both; what these examples pin is the wiring.
    #
    # Isolation is total and deliberate: a repo-mode epics home under the
    # tmpdir, plus an XDG state home inside it, so neither this developer's
    # real epics nor their real session journals can decide an example.
    describe "the epic tier's request_review tool" do
      require "fileutils"

      def with_state_home(path)
        was = ENV.fetch("XDG_STATE_HOME", nil)
        ENV["XDG_STATE_HOME"] = path
        yield
      ensure
        ENV["XDG_STATE_HOME"] = was
      end

      # Written straight to the repo-mode layout rather than through
      # {Epic::Home}: an epic exists once its document is on disk, and this
      # spec is about the wiring above that, not about path arithmetic.
      def create_epic(dir, slug)
        graph = Lain::Epic::Graph.new(issues: [Lain::Epic::Issue.new(id: "a1", title: "the a1 issue")])
        path = File.join(dir, ".lain", "epics", slug, "epic.md")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, Lain::Epic::Document.to_markdown(graph))
      end

      def in_project(*slugs)
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, ".lain"))
          File.write(File.join(dir, ".lain", "config.toml"), %([epics]\nhome = "repo"\n))
          slugs.each { |slug| create_epic(dir, slug) }
          with_state_home(File.join(dir, "state")) { Dir.chdir(dir) { yield(dir) } }
        end
      end

      def toolset_named(options: { grace: 5 })
        mounted = described_class.new(options:, chronicle:, status_feed:)
        recorder, session = mounted.run_state(nil)
        mounted.wire_agent(channel:, recorder:, session:, backend:).toolset.names
      end

      def run_in(dir, options: { grace: 5 }, &notice)
        wiring = described_class.new(options:, chronicle:, status_feed:,
                                     tty_factory: tty_factory("quit\n", dir), conductor_opener:)
        wiring.run(backend:, resumed: nil, nvim: nil, &notice)
        wiring.conductor.close(reason: :exit)
        wiring
      end

      it "wires the tool when the project's sole epic resolves" do
        in_project("alpha") { expect(toolset_named).to include("request_review") }
      end

      it "wires the tool for the epic --epic names" do
        in_project("alpha", "beta") do
          expect(toolset_named(options: { grace: 5, epic: "beta" })).to include("request_review")
        end
      end

      # A chat must never fail to start over this, and a tool that cannot act
      # must not be offered to the model.
      it "leaves the tool out, and says why, when the home holds several epics and none was named" do
        in_project("alpha", "beta") do |dir|
          said = []

          expect(toolset_named).not_to include("request_review")
          run_in(dir) { |notice| said << notice }
          expect(said.join).to include("--epic")
        end
      end

      # The ordinary chat: no epic anywhere, no tool, and nothing said.
      it "starts a chat with no epic home at all, silently" do
        Dir.mktmpdir do |dir|
          with_state_home(File.join(dir, "state")) do
            Dir.chdir(dir) do
              said = []

              expect(toolset_named).not_to include("request_review")
              expect { run_in(dir) { |notice| said << notice } }.not_to raise_error
              expect(said).to be_empty
            end
          end
        end
      end

      # {HumanReplies} is built in #build_repl, strictly AFTER the toolset --
      # so the tool holds a thunk, and what it must read at CALL time is the
      # run's ONE live replies object, the same one the Env hands the commands.
      it "late-binds the tool to the live HumanReplies the run built" do
        in_project("alpha") do |dir|
          wiring = run_in(dir)
          tool = wiring.command_env.agent.toolset.fetch("request_review")

          expect(tool.send(:bindings)).to equal(wiring.command_env.replies)
        end
      end

      # T31a, AND THE REASON THIS GROUP NEEDED MORE THAN IT HAD. This wiring
      # mounted the epic with `notify:` and `bindings:` only, so `changesets:`
      # and `surface:` stayed nil, `Implementation#hold` answered
      # `Refusals.no_changeset` on every call in every real process, and the
      # surface resolved to the Null. NOTHING AMONG 10865 EXAMPLES COULD SEE IT:
      # every existing example of the changeset half passes those seams in by
      # hand. These two drive the PRODUCTION mount instead -- real git, the real
      # thunks -- and answer the review on the rail an editor answers it on.
      describe "the changeset half of that tool, over the wiring the exe uses", :seam do
        # The frontend, reduced to the three messages {HumanReplies} asks of one
        # ({Frontend::Neovim} answers exactly these). The surface is the REAL
        # text one and the view the REAL sidebar view: what is under test is
        # whether the tool reaches THESE rather than its nulls, and a double
        # answering the port would be indistinguishable from `Surface::Null`.
        def review_editor(sink)
          view = Lain::Frontend::Neovim::ReviewView.new
          surface = Lain::Review::Surface::Text.new(sink:)
          Object.new.tap do |editor|
            editor.define_singleton_method(:review_surface) { surface }
            editor.define_singleton_method(:review_view) { view }
            editor.define_singleton_method(:bound) { @bound }
            editor.define_singleton_method(:bind_changeset_review) { |review| @bound = review }
          end
        end

        # A project that is BOTH an epic home and a git repository with
        # something to review, because {Wiring#epic_mount} builds its changeset
        # source over the resolved project's ROOT ({CLI::ReviewSeams.for}'s
        # `root:`): the two have to be one directory. It read `Dir.pwd` when
        # this was written, and named a `#review_seams` that never existed.
        # The epic's own files are written AFTER the commit, so they stay
        # untracked and the changeset under review is the one file this example
        # is about. Committed first, the epic document is in the diff too --
        # which is not wrong, but it makes the review two files wide for no
        # reason and every hunk of it has to be marked before a verdict is
        # admissible.
        def in_repo(slug: "alpha")
          Dir.mktmpdir do |dir|
            FileUtils.cp_r(File.join(SeedRepo.at("README" => "seed\n"), "."), dir)
            commit(dir)
            FileUtils.mkdir_p(File.join(dir, ".lain"))
            File.write(File.join(dir, ".lain", "config.toml"), %([epics]\nhome = "repo"\n))
            create_epic(dir, slug)
            with_state_home(File.join(dir, "state")) { Dir.chdir(dir) { yield(dir) } }
          end
        end

        # The second commit, so `HEAD~1..HEAD` is a real one-file changeset.
        def commit(dir)
          File.write(File.join(dir, "README"), "seed\nthe line under review\n")
          [%w[add -A], ["commit", "-q", "-m", "the work under review"]].each do |argv|
            Mixlib::ShellOut.new("git", "-C", dir, *argv,
                                 environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command.error!
          end
        end

        def invocation = Lain::Tool::Invocation.new(context: Lain::Session::Null.instance)

        # The hand-over whole, as a human doing it would: the tool parks, the
        # editor's own rail is handed a review, the human answers it there.
        # `pumped_until` and not a bare `task.yield`: the call shells out to git
        # before it binds anything, so the moment the rail is handed a review is
        # several reactor turns away and a fixed number of yields would be a
        # guess. Bounded, so a review that never binds is a failing example
        # naming the condition rather than a hang.
        def reviewed(wiring, editor)
          tool = wiring.command_env.agent.toolset.fetch("request_review")
          result = nil
          Sync do |task|
            call = task.async { result = tool.call({ "stage" => "implementation", "base" => "HEAD~1" }, invocation) }
            pumped_until(task, reason: "the editor's rail was handed a review") { editor.bound }
            yield
            call.wait
          end
          result
        end

        # The human's whole side of it, on the objects the wiring supplied: read
        # the sidebar the editor's OWN view drew, mark the row, answer.
        #
        # The mark is not decoration. This wiring passes no `policy:`, so the
        # tool takes {Verdict::Policy.default} -- `EveryHunk`, which refuses an
        # approve over hunks nobody read -- and a verdict refused leaves the call
        # parked. So `be_ok` below holds only if the mark reached the session
        # THROUGH the view the wiring injected, which is what makes one
        # assertion cover all three seams.
        def marked_and_approved(editor)
          handover = editor.bound
          rendering = editor.review_view.render(handover.session.marked, scope: :cumulative)
          row = rendering.lines.index { |line| line.include?("README") } + 1
          handover.mark(row, "reviewed", generation: rendering.generation)
          handover.wrote_verdict("approve")
        end

        it "supplies a changeset source, a view and a rail, so the stage opens and a verdict settles it" do
          in_repo do |dir|
            wiring = run_in(dir)
            editor = review_editor(StringIO.new)
            wiring.command_env.replies.bind_review_editor(editor)

            result = reviewed(wiring, editor) { marked_and_approved(editor) }

            expect(result).to be_ok
            expect(result.content).to include("approve").and include("review-changeset-v1:")
          end
        end

        it "supplies the editor's own surface and view, and not the nulls that stood in for them" do
          in_repo do |dir|
            wiring = run_in(dir)
            sink = StringIO.new
            editor = review_editor(sink)
            wiring.command_env.replies.bind_review_editor(editor)
            gesture = nil

            reviewed(wiring, editor) do
              # The VIEW, told apart from {Handover::Detached} by whose sentence
              # comes back: a live view says nothing has been rendered into IT
              # yet, and the null says there is no editor at all. Two facts, and
              # a tool holding the null would answer the wrong one.
              gesture = editor.bound.open(1, generation: nil)
              marked_and_approved(editor)
            end

            expect(sink.string).to include("README")
            expect(gesture.report).to include("lain://review")
          end
        end
      end
    end
  end

  # T5: the run's {Lain::Project}, threaded. Five collaborators used to reach
  # `Dir.pwd` for themselves, which made "where is this project" a question
  # five objects answered independently -- and answered WRONG from a
  # subdirectory, where the root is up the tree and the cwd is not it.
  #
  # NOTHING HERE CHDIRS, and that is the whole design of the block: the process
  # working directory stays the repository this suite runs in, so every
  # assertion below distinguishes the injected project from `Dir.pwd` rather
  # than watching the two agree by construction.
  describe "the resolved project" do
    require "fileutils"
    require "tmpdir"

    # A root with a real subdirectory to sit in, so root and cwd are DIFFERENT
    # directories and an assertion can say which one a collaborator got.
    # Realpath'd because {Lain::Project} resolves, and a tmpdir is a symlink on
    # more boxes than not.
    #
    # The XDG state home moves under the tree for {Lain::CLI::EpicMount}'s
    # sake -- the group one describe up does the same -- so this developer's
    # real epics can never decide an example.
    def in_project_tree
      Dir.mktmpdir("lain-t5-project") do |dir|
        root = File.realpath(dir)
        cwd = File.join(root, "services", "ingest")
        FileUtils.mkdir_p(cwd)
        with_env("XDG_STATE_HOME" => File.join(root, "state")) { yield(root, cwd) }
      end
    end

    def project_at(root, cwd) = Lain::Project.new(root:, cwd:, kind: :project, detected_by: :flag)

    def wiring_for(project, options: { grace: 5 })
      described_class.new(options:, chronicle:, status_feed:, project:)
    end

    # The whole run, so {Lain::CLI::Command::Surface} exists: it is built in
    # #build_repl, which only #run reaches. The conductor opener is the real
    # default -- what is under test is the project, not the seams the #run
    # group above already drives.
    def run_project(project, options: { grace: 5 })
      Dir.mktmpdir("lain-t5-tty") do |dir|
        wiring = described_class.new(options:, chronicle:, status_feed:, project:,
                                     tty_factory: project_tty_factory("quit\n", dir))
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
        wiring
      end
    end

    def project_tty_factory(input, dir)
      lambda do |channel:, **|
        Lain::Frontend::TTY.new(channel:, output: StringIO.new, input: StringIO.new(input),
                                history_path: File.join(dir, "history"))
      end
    end

    it "runs the chat's Session in the project's CWD, which is not its root" do
      in_project_tree do |root, cwd|
        _, session = wiring_for(project_at(root, cwd)).run_state(nil)

        expect(session.worker_env.cwd).to eq(cwd)
      end
    end

    # The env half of the WorkerEnv is untouched: this card moves the working
    # directory a chat's tools resolve against, and nothing else about the
    # host-side execution context.
    it "leaves the chat's environment snapshot exactly as WorkerEnv.default takes it" do
      in_project_tree do |root, cwd|
        _, session = wiring_for(project_at(root, cwd)).run_state(nil)

        expect(session.worker_env.env).to eq(Lain::WorkerEnv.default.env)
      end
    end

    # Spies rather than effect-reading, for one reason: three of the four
    # consume the root into a path they then only use on the way to git or to
    # disk, so what a spec could see afterwards is a derived artifact and not
    # the root. What is under test is the THREADING, and the argument IS the
    # threading. The two that leave a readable trace get it asserted below as
    # well.
    it "hands the isolation backend, epic mount, review seams and command surface the ROOT" do
      allow(Lain::CLI::IsolationBackend).to receive(:resolve).and_call_original
      allow(Lain::CLI::EpicMount).to receive(:for).and_call_original
      allow(Lain::CLI::ReviewSeams).to receive(:for).and_call_original
      allow(Lain::CLI::Command::Surface).to receive(:new).and_call_original

      in_project_tree do |root, cwd|
        run_project(project_at(root, cwd))

        expect(Lain::CLI::IsolationBackend).to have_received(:resolve).with(anything, hash_including(root:))
        expect(Lain::CLI::EpicMount).to have_received(:for).with(hash_including(root:))
        expect(Lain::CLI::ReviewSeams).to have_received(:for).with(anything, root:)
        expect(Lain::CLI::Command::Surface).to have_received(:new).with(hash_including(root:))
      end
    end

    # The surface's own trace, so the spy above is not the only witness: `/meta`,
    # `/review` and `/review-submit` are each constructed with this root.
    it "leaves that root where /meta and the two review commands read it" do
      in_project_tree do |root, cwd|
        surface = run_project(project_at(root, cwd)).command_surface

        expect(surface.instance_variable_get(:@root)).to eq(root)
      end
    end

    # A run whose cwd is a subdirectory still journals against the project, and
    # the two are asserted TOGETHER because the pair is the point: the tools
    # work where the user is, the project-scoped collaborators work where the
    # project is.
    it "sends the cwd to the Session and the root to the collaborators, from one Project" do
      in_project_tree do |root, cwd|
        wiring = run_project(project_at(root, cwd))

        expect(wiring.command_env.agent.session.worker_env.cwd).to eq(cwd)
        expect(wiring.command_surface.instance_variable_get(:@root)).to eq(root)
      end
    end

    # AC4: with nothing injected the default resolves the process's own
    # project, and a chat started in a directory that IS its own root gets the
    # WorkerEnv it got before this card existed -- byte for byte.
    describe "the default" do
      it "is byte-identical to WorkerEnv.default when the cwd is its own root" do
        Dir.mktmpdir("lain-t5-default") do |dir|
          Dir.chdir(File.realpath(dir)) do
            _, session = described_class.new(options: { grace: 5 }, chronicle:, status_feed:).run_state(nil)

            expect(session.worker_env).to eq(Lain::WorkerEnv.default)
          end
        end
      end

      it "resolves the working directory's own project" do
        Dir.mktmpdir("lain-t5-default") do |dir|
          Dir.chdir(File.realpath(dir)) do
            project = described_class.new(options: { grace: 5 }, chronicle:, status_feed:).project

            expect([project.root, project.cwd]).to eq([File.realpath(dir), File.realpath(dir)])
          end
        end
      end

      # THE EXAMPLE THAT MAKES THE TWO ABOVE MEAN SOMETHING. Both of them chdir
      # into a bare tmpdir that is its own root, so `root == cwd` holds by
      # construction and `Dir.pwd` would satisfy them exactly as the resolver
      # does -- the T5 review demonstrated it: replacing #default_project's body
      # with `Project.new(root: Dir.pwd, cwd: Dir.pwd, ...)` reverted the whole
      # card at its one production entry point and left every delivered example
      # green. This one WALKS: `.lain/` is two directories up, so the two fields
      # must differ, and only a resolution can tell them apart.
      #
      # `HOME` is injected at the tmpdir base so the walk's stop rule is the
      # fixture's and not this developer's, exactly as {Project::Resolver}
      # requires its home to be given rather than guessed.
      it "walks for the root, so a chat started in a subdirectory gets root != cwd" do
        Dir.mktmpdir("lain-t5-walk") do |dir|
          base = File.realpath(dir)
          root = File.join(base, "repo")
          cwd = File.join(root, "services", "ingest")
          FileUtils.mkdir_p(File.join(root, ".lain"))
          FileUtils.mkdir_p(cwd)

          with_env("HOME" => base) do
            Dir.chdir(cwd) do
              project = Lain::Project::Resolver.default_project

              expect(project.root).to eq(root)
              expect(project.cwd).to eq(cwd)
              expect(project.root).not_to eq(project.cwd)
            end
          end
        end
      end

      # And what that resolution BUYS at the wiring, since #default_project
      # answering correctly is worth nothing if the instance then ignores it:
      # the Session's cwd comes from the project the instance resolved for
      # ITSELF, with nothing injected. The root half below is the attr_reader
      # read back, not a threading -- what the collaborators do with the root is
      # the injected-project group above, which can tell root from cwd.
      it "threads its own resolution into the Session's working directory" do
        Dir.mktmpdir("lain-t5-walk-wired") do |dir|
          base = File.realpath(dir)
          root = File.join(base, "repo")
          cwd = File.join(root, "services", "ingest")
          FileUtils.mkdir_p(File.join(root, ".lain"))
          FileUtils.mkdir_p(cwd)

          with_env("HOME" => base, "XDG_STATE_HOME" => File.join(base, "state")) do
            Dir.chdir(cwd) do
              wiring = described_class.new(options: { grace: 5 }, chronicle:, status_feed:)
              _, session = wiring.run_state(nil)

              expect(session.worker_env.cwd).to eq(cwd)
              expect(wiring.project.root).to eq(root)
            end
          end
        end
      end
    end
  end

  # T23. Every OTHER spec of this boundary passes by handing a classifier in,
  # and production handed one in nowhere -- `Switchboard.for` never passed
  # `sensitivity:`, so the constructor's Null default stood and `gates?`
  # answered false for every path in every real chat. So nothing here injects a
  # classifier or a policy: each example builds a chat the way #run does,
  # through #wire_agent, and reads the board that assembly memoized. An example
  # that passed a Sensitivity in would prove exactly what the last twenty-two
  # cards' specs proved, which is nothing.
  describe "the path boundary a real chat builds" do
    def board_for(root:, cwd: root)
      wiring = wired(root:, cwd:)
      # The memo #build_agent assigned -- arguments ignored, since `||=` has
      # already answered. Reaching for it privately rather than adding a public
      # reader: the board IS this run's authority, and nothing in lib/ asks
      # Wiring for it.
      wiring.send(:switchboard, backend, nil)
    end

    def wired(root:, cwd: root, chronicle: self.chronicle)
      wiring = described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                                   project: Lain::Project.new(root:, cwd:, kind: :project, detected_by: :flag))
      recorder, session = wiring.run_state(nil)
      wiring.wire_agent(channel:, recorder:, session:, backend:)
      wiring
    end

    def read_of(path) = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file", input: { "path" => path })

    # The reason the board's own classifier gave, asked through the surface
    # that reports one. `gates?` answers a Boolean, and the GATED half of the
    # table carries its verdict out through exactly one production reader --
    # the listing filter's withheld rows, which is what prints `2 paths
    # withheld (credential)`. So this is the board's real answer, not a second
    # classifier built to the same recipe, and it needs no reach past the Policy.
    def verdict_for(board, path) = board.sensitivity.filter.sift([path]) { |row| [row] }.withheld.first

    # `HOME` is injected at the tmpdir base for the reason the T5 walk group
    # above injects it: the home-ANCHORED half of the classifier's denied table
    # is built from it, so a fixture reading this developer's real home would
    # assert against a directory nobody controls. {Lain::Paths} is where the
    # boundary reads it, and it reads the environment it is given.
    def in_tree(config: nil)
      Dir.mktmpdir("lain-t23") do |dir|
        base = File.realpath(dir)
        root = File.join(base, "repo")
        home = File.join(base, "home")
        FileUtils.mkdir_p(File.join(root, ".lain"))
        File.write(File.join(root, ".lain", "config.toml"), config) if config
        with_env("HOME" => home, "XDG_STATE_HOME" => File.join(base, "state")) { yield(root, home) }
      end
    end

    it "gates a credential-shaped path under the project root" do
      in_tree do |root|
        board = board_for(root:)

        expect(board.sensitivity.gates?(read_of(File.join(root, ".env")))).to be(true)
      end
    end

    it "names a credential as the reason it gated one" do
      in_tree do |root|
        verdict = verdict_for(board_for(root:), File.join(root, ".env"))

        expect([verdict&.level, verdict&.reason]).to eq(%i[gated credential])
      end
    end

    it "leaves an ordinary path ungated" do
      in_tree do |root|
        board = board_for(root:)

        expect(board.sensitivity.gates?(read_of(File.join(root, "README.md")))).to be(false)
      end
    end

    # No config at all: the built-in tables are what a project gets, and the
    # unambiguous half of the denied table matches wherever it sits.
    it "denies a private key with no config to say so" do
      in_tree do |root, home|
        denial = board_for(root:).sensitivity.denial(read_of(File.join(home, ".ssh", "id_rsa")))

        expect([denial&.path, denial&.reason]).to eq([File.join(home, ".ssh", "id_rsa"), :protected])
      end
    end

    # The home-ANCHORED half of the same table, which is the half that can only
    # work if the injected home actually reached the classifier: `.kube/config`
    # is denied under this run's home and ordinary anywhere else.
    it "anchors the home-relative rules at the home it was given" do
      in_tree do |root, home|
        board = board_for(root:)

        expect(board.sensitivity.denial(read_of(File.join(home, ".kube", "config")))&.reason).to eq(:protected)
        expect(board.sensitivity.denial(read_of(File.join(root, ".kube", "config")))).to be_nil
      end
    end

    it "denies what the project's own [sensitivity] table denies, in the project's own words" do
      in_tree(config: "[sensitivity]\ndenied = [\"*.secret\"]\n") do |root|
        denial = board_for(root:).sensitivity.denial(read_of(File.join(root, "prod.secret")))

        expect(denial&.reason).to eq(:configured)
        expect(denial&.verdict&.explanation).to eq("named by this project's sensitivity config")
      end
    end

    it "gates what the project's [sensitivity] table merely gates" do
      in_tree(config: "[sensitivity]\ngated = [\"*.private\"]\n") do |root|
        board = board_for(root:)

        expect(board.sensitivity.gates?(read_of(File.join(root, "notes.private")))).to be(true)
        expect(board.sensitivity.denial(read_of(File.join(root, "notes.private")))).to be_nil
      end
    end

    # LOUD, and not rescued the way a broken [approval] table is: that one
    # grants, so dropping it fails closed; this one restricts, so a session that
    # ran with it silently un-parsed would be running with the project's
    # denials off.
    it "refuses a malformed [sensitivity] table at construction, naming the file" do
      in_tree(config: "sensitivity = \"strict\"\n") do |root|
        expect { wired(root:) }
          .to raise_error(Lain::Sensitivity::Rules::NotATable,
                          /#{Regexp.escape(File.join(root, ".lain", "config.toml"))}.*must be a table/)
      end
    end

    # BEFORE the session header is pinned, which is {Wiring#fleet_isolation}'s
    # stated ordering one method away: a refusal after `chronicle.start` leaves
    # a session record on disk for a chat that never ran. `#start` is what
    # builds the Scribe, and the Scribe writes the header in its constructor, so
    # "start was never called" IS "no orphan record".
    it "refuses before the session record is opened, leaving no orphan header" do
      in_tree(config: "sensitivity = \"strict\"\n") do |root|
        spy = WiringSpecStartSpy.new(Lain::CLI::Chronicle::Null.new)

        expect { wired(root:, chronicle: spy) }.to raise_error(Lain::Sensitivity::Rules::NotATable)
        expect(spy.starts).to eq(0)
      end
    end

    # And the converse, so the ordering above is not satisfied by never starting
    # at all: an ordinary chat still pins its header.
    it "still opens the session record when the config is fine" do
      in_tree do |root|
        spy = WiringSpecStartSpy.new(Lain::CLI::Chronicle::Null.new)
        wired(root:, chronicle: spy)

        expect(spy.starts).to eq(1)
      end
    end

    # F2's ruling, at the session: the strict compile is the sensitivity table's
    # alone. A typo in a table this boundary never reads costs that table's
    # feature, never the chat -- which is how it was before this card, and how a
    # user mid-task needs it to stay.
    it "does not take the session down for a typo in an unrelated table" do
      in_tree(config: %(epics = "not a table"\n\n[sensitivity]\ndenied = ["*.secret"]\n)) do |root|
        board = board_for(root:)

        expect(board.sensitivity.denial(read_of(File.join(root, "prod.secret")))&.reason).to eq(:configured)
      end
    end

    it "keeps the built-in rules when the config file will not parse at all" do
      in_tree(config: "this is not [valid toml") do |root, home|
        board = board_for(root:)

        expect(board.sensitivity.denial(read_of(File.join(home, ".ssh", "id_rsa")))&.reason).to eq(:protected)
        expect(board.sensitivity.gates?(read_of(File.join(root, ".env")))).to be(true)
      end
    end

    # The child's half of the same wiring: {ToolsetBuild::LiveSensitivity}
    # delegates to `board.sensitivity` per call, so a subagent asks THIS
    # classifier. It answered the Null's false until the board held a real one.
    it "hands the same classifier to the subagent seam" do
      in_tree do |root|
        live = wired(root:).send(:toolset_build).send(:seam).sensitivity

        expect(live.gates?(read_of(File.join(root, ".env")))).to be(true)
      end
    end

    # The TOOL phase, from the production board. Two independent things had to
    # be true for this axis to fire, and asserting only one is how the card
    # half-lands and looks done: the stack has to CARRY the listing guard, and
    # that guard's filter has to be a live one rather than the Null. Both here,
    # in one example, over the board a real chat built.
    describe "the tool phase over that board" do
      def listing_guard(board)
        Lain::CLI::ToolGuard.stack(chronicle, board).to_a.grep(Lain::Middleware::WithholdSecretPaths).first
      end

      it "carries the listing guard, filtering through the board's own classifier" do
        in_tree do |root|
          board = board_for(root:)

          expect(Lain::CLI::ToolGuard.stack(chronicle, board).to_a.map(&:class))
            .to eq([Lain::Middleware::RefuseSecretWrites, Lain::Middleware::RedactSecretReads,
                    Lain::Middleware::WithholdSecretPaths])
          expect(listing_guard(board).filter).to be(board.sensitivity.filter)
          expect(listing_guard(board).filter).not_to be(Lain::Sensitivity::Filter::Null.instance)
        end
      end

      # And what that buys, end to end: a listing that names a credential-shaped
      # path has that row dropped, with the count and the reason reported --
      # never silently, because a truncated listing reads as "that is
      # everything" and the agent acts on it.
      it "withholds a credential-shaped row from a listing, and says so" do
        in_tree do |root|
          sifted = listing_guard(board_for(root:))
                   .filter.sift([File.join(root, "README.md"), File.join(root, ".env")]) { |row| [row] }

          expect(sifted.kept).to eq([File.join(root, "README.md")])
          expect([sifted.count, sifted.reasons]).to eq([1, [:credential]])
        end
      end
    end
  end
end
