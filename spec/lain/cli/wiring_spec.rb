# frozen_string_literal: true

require "async"
require "json"
require "stringio"
require "tmpdir"

# Stands in for the eager tier's local model (production wires an Ollama-backed
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

# The launch block's stand-in for an adopted actor: it builds the child's
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

# An actor that CRASHED after committing in its leased checkout: dead from the
# moment it launched, stopped only when the supervisor farewells it. The commit
# is made inside the launch block, while the lease is live, because that is the
# work a reap has to save.
class WiringSpecCrashedWorker
  attr_reader :commit

  def initialize(worker_env)
    @worker_env = worker_env
    dir = worker_env.cwd
    File.write(File.join(dir, "crashed.txt"), "work a crash left behind\n")
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", "crashed work")
    @commit = git(dir, "rev-parse", "HEAD")
    @stopped = false
  end

  # Where it stands, which the supervisor checks against its lease.
  def session = Lain::Session.new(worker_env: @worker_env)

  def stop
    @stopped = true
    self
  end

  def stopped? = @stopped

  def dead? = true

  private

  def git(dir, *)
    shell = Mixlib::ShellOut.new("git", "-C", dir, *, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
    shell.run_command.error!
    shell.stdout.strip
  end
end

# Counts the calls to `#start` and is otherwise the chronicle it wraps. The
# refusal group below needs an ORDERING claim -- that a config refusal lands
# before the session record is opened -- and `#start` is the moment that record
# exists: it builds the {Lain::SessionRecord::Scribe}, whose constructor writes
# the header. So "start was never called" is exactly "no orphan header on
# disk", asserted without parsing journal bytes.
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

# The two members {Lain::CLI::Wiring#run_state} reads off a resume result. A
# Data rather than a double because what is asserted is identity -- the
# recorder that comes back IS the one resumed -- and a double answering a fresh
# object on each call could not show that.
WiringSpecResumed = Data.define(:recorder, :session)

# Records what the backend was asked for a provider WITH, because
# {Lain::CLI::Wiring}'s `#spooled_provider` has as its whole content the pair
# of keywords it passes -- the spool tee and the channel -- and the object that
# comes back is the same mock either way. Only the network edge is faked; the
# rest is the real {Lain::CLI::Backend} the exe builds.
class WiringAgentSpecBackend < Lain::CLI::Backend
  attr_reader :provider_calls

  def initialize(options, mock:, root: Dir.pwd)
    super(options, root:)
    @mock = mock
    @provider_calls = []
  end

  def provider(**kwargs)
    @provider_calls << kwargs
    @mock
  end

  # Wrapped IN PLACE OF {Lain::CLI::Backend}'s own memo, deliberately: `super`
  # fills `@context_window` with the real book, and this assignment then
  # replaces it with the counting wrapper -- so there is one object, and it is
  # the one the wiring hands the Agent. Counting on a second book built to
  # observe would answer a question nobody is asking.
  def context_window = @context_window ||= WiringAgentSpecWindow.new(super)
end

# Counts the re-resolutions the turn stack triggers and delegates the three
# reader messages, so "the trigger fired on the run's own book" is a property
# an example can see. A real {Lain::CLI::Backend::WindowBook::Live} answers the
# same duck and would count nothing.
class WiringAgentSpecWindow
  attr_reader :refreshes, :trail

  # `trail` is SHARED with the chronicle's turn member in the ordering example
  # below, because a list of classes says what the stack holds and not what ran
  # first -- and it is the running order three docstrings call load-bearing.
  def initialize(book, trail = [])
    @book = book
    @refreshes = 0
    @trail = trail
  end

  def reresolve
    @refreshes += 1
    @trail << :window
    @book.reresolve
  end

  def resolve(model) = @book.resolve(model)
  def window_tokens(model) = @book.window_tokens(model)
  def occupancy(used_tokens, model:) = @book.occupancy(used_tokens, model:)
end

# Captures the timeline handle the agent build hands the chronicle so an example
# can call it back AFTER the Agent exists. That is the only way to see whether
# the closure caught a live binding or a permanent nil -- the defect
# `wiring.rb` documents at its own `@agent = build_agent(...)` line.
class WiringAgentSpecChronicle < Lain::CLI::Chronicle::Null
  attr_reader :timeline_handle

  # The record journal a live chat writes its `capability_degraded` records to.
  # Defaulted to the Null's own /dev/null one, so every group that does not read
  # bytes back behaves exactly as it did before the keyword existed.
  def initialize(record_journal = nil)
    @record_journal = record_journal
    super()
  end

  def record_journal = @record_journal || super

  def turn_middleware(timeline)
    @timeline_handle = timeline
    super
  end

  # MEMOIZED where the Null answers a fresh spool per call, so "the provider
  # was teed into THE chronicle's spool" is an identity an example can assert
  # at all. Against the unmemoized one every comparison is between two distinct
  # Nulls and passes for the wrong reason -- or fails for it.
  def spool = @spool ||= super
end

# A chronicle whose turn phase is NOT empty.
#
# Written because the ordering assertions against the Null chronicle CANNOT
# FAIL: its `turn_middleware` is an empty Stack, so `[ResolveWindow, *[]]` and
# `[*[], ResolveWindow]` are the same list, and a mutant moving the refresh to
# the innermost position survived the entire suite. Benign today -- JournalTurns
# runs its work after `downstream` and reads no window -- but the ordering is
# stated as load-bearing in three docstrings, and a documented claim that
# nothing holds is the shape this chunk keeps producing.
class WiringAgentSpecJournallingChronicle < WiringAgentSpecChronicle
  # Named so the ordering reads as a list of classes, and RECORDING so the same
  # example can pin what actually ran first.
  class Member < Lain::Middleware::Base
    def initialize(trail)
      @trail = trail
      super()
    end

    def call(env, &app)
      @trail << :chronicle
      downstream(env, &app)
    end
  end

  def initialize(trail)
    @trail = trail
    super()
  end

  def turn_middleware(_timeline) = Lain::Middleware::Stack.new([Member.new(@trail)])
end

# The Switchboard's side of the seam, recorded. A stand-in rather than the real
# board because the point of the seam is that the agent build is HANDED one:
# what an example needs to see is which object the Agent was built over, and
# that {Lain::CLI::Wiring}'s `#agent_over` never went looking for one of its own.
class WiringAgentSpecBoard
  attr_reader :toolset, :grafted, :ledger, :approvals, :sensitivity, :snapshots, :policy_switch

  # A real board writes under `:shadow_git`; the stand-in
  # answers the write-set scope so building an Agent over it shells no git.
  def snapshot_scope = :write_set

  def bind_snapshots(slot)
    @snapshots = slot
  end

  # The session a flip into plan scope confines.
  attr_reader :session

  def bind_session(session)
    @session = session
    self
  end

  # The run's ONE region ledger, the approval queue an unattended board leaves
  # nil, and the path policy -- all real, because the three tool-phase guards
  # take them as required keywords with no default and a double answering nil
  # for any of them would test a construction production cannot reach.
  #
  # `sensitivity` joined that list when {CLI::ToolGuard} started
  # reading the listing filter off the board's policy instead of passing a
  # Null. It is the slot a real {CLI::Switchboard} has always had; this
  # stand-in simply had no reason to answer it until something asked.
  def initialize(toolset, approvals: nil)
    @toolset = toolset
    @grafted = []
    @policy_switch = Lain::Middleware::Gate::ApproveAll.new
    @ledger = Lain::Sensitivity::Ledger.new
    @approvals = approvals
    @sensitivity = Lain::Sensitivity::Policy.new(
      sensitivity: Lain::Sensitivity.new(home: "/home/tester", cwd: "/home/tester/project")
    )
  end

  # The one value the tool stack is built over, as a real board holds it: these
  # same slots, a test layout run declaring none, and a gate policy approving
  # every call, which an example can tell apart from any other by identity.
  def guard_inputs
    @guard_inputs ||= Lain::CLI::ToolGuard::Inputs.new(
      ledger:, approvals:, sensitivity:, test_layout: Lain::Middleware::GuardTestLayout::Run.undeclared,
      policy: policy_switch, policy_for: ->(_worker_env) { policy_switch }, denial: Lain::Middleware::Gate::DENIAL,
      bar: Lain::Middleware::WithholdAutomaticOutput::Bar.new
    )
  end

  def graft(context)
    @grafted << context
    context
  end
end

RSpec.describe Lain::CLI::Wiring do
  # Provider resolution, context, slots, and spawn policies stay the real
  # Backend's; only the network edge swaps for Provider::Mock, so the whole
  # chat assembly is exercised offline exactly as the exe wires it (the
  # extracted Repl is constructible without the exe).
  let(:offline_backend_class) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:, root: Dir.pwd)
        super(options, root:)
        @mock = mock
      end

      def provider(**) = @mock
    end
  end

  # What the default Context asks of a provider, read off a Context rather than
  # a snapshot: the answer belongs to the pipeline in effect.
  let(:default_requires) { Lain::Context.new(model: "any", max_tokens: 1).requires }

  let(:mock_provider) do
    Lain::Provider::Mock.new(responses: [
                               Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                  stop_reason: :end_turn)
                             ])
  end
  let(:backend) { offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: mock_provider) }

  # A provider that answers BOTH questions the occupancy pin below needs of
  # one: what window it is serving (`Provider#context_window_tokens`, which the
  # base class answers nil for) and a turn whose usage gives `#occupancy` a
  # numerator.
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
  # status_feed: is required, not defaulted (the Null placeholder is gone). The
  # direct-Wiring path threads it into the Command::Env's status reader -- and
  # #run hands it the run's Store, which is the ONE line that makes the HUD's
  # inbox_count able to retire anything. Stubbed rather than doubled away
  # so the #run group below can assert that call actually happened.
  let(:status_feed) { instance_double(Lain::StatusFeed, bind_store: nil) }
  let(:wiring) { described_class.new(options: { grace: 5 }, chronicle:, status_feed:) }

  def wire_agent
    recorder, session = wiring.run_state(nil)
    wiring.wire_agent(channel:, recorder:, session:, backend:)
  end

  # The 2026-08-05 defect, at the site it fired from -- and the surface it fired
  # from is now deleted. This call built a real dunstify adapter unconditionally,
  # so every spec, probe and experiment that reached #wire_agent notified the
  # human running the machine: nine notifications landed on a working human's
  # desktop, `appname: lain`, from agents' trees. The gate written for it was
  # consent BEFORE capability; removing the surface answers the same question by
  # construction.
  #
  # The `dunstify` put on PATH here RECORDS rather than merely exits, and that
  # is the point of it: a fake that only exits would be scenery, passing whether
  # or not anything tried to notify. This one writes its argv to a witness file,
  # so the first example fails if any line reached by a wired chat shells out to
  # the human's notification daemon -- capability restored to PATH, and nothing
  # taking it.
  describe "the desktop surface a chat no longer has" do
    let(:witness) { File.join(@dunstify_dir, "fired") }

    around do |example|
      Dir.mktmpdir do |dir|
        @dunstify_dir = dir
        fake = File.join(dir, "dunstify")
        File.write(fake, "#!/bin/sh\nprintf '%s\\n' \"$@\" >> #{File.join(dir, "fired")}\nexit 0\n")
        File.chmod(0o755, fake)
        with_env("PATH" => "#{dir}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}") do
          example.run
        end
      end
    end

    it "assembles a chat that answers, and nothing in it reaches the notification daemon" do
      wiring = described_class.new(options: { grace: 5 }, chronicle:, status_feed:)
      recorder, session = wiring.run_state(nil)
      agent = wiring.wire_agent(channel:, recorder:, session:, backend:)

      expect(agent.ask("ping").text).to eq("settled")
      expect(wiring).not_to respond_to(:notifier)
      expect(File).not_to exist(witness)
    end

    # The structural half, and the one that makes the example above an
    # invariant rather than an observation: there is no adapter left to build,
    # so no consent and no capability can reintroduce one.
    it "offers no desktop notification surface at all, so consent has nothing left to turn on" do
      expect(Lain).not_to be_const_defined(:Notify)
    end
  end

  describe "#wire_agent" do
    it "builds the Agent over the injected backend's provider, no exe involved" do
      agent = wire_agent
      expect(agent).to be_a(Lain::Agent)
      expect(agent.ask("ping").text).to eq("settled")
      expect(mock_provider.call_count).to eq(1)
    end

    # The parent handle is ONE Proc, equal?-shared by AskHuman and
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

    # ---- session_usage: the fix, at the seam that made the failure possible --

    # Asked what its own session had spent, the agent invented a metrics table
    # -- wrong model name, fabricated memory/CPU/RTT/network figures -- while
    # eight `turn_usage` records carrying the true answer sat in the journal it
    # had just written. Nothing in the shipped toolset could reach the run's own
    # accounting, so the model answered from nowhere.
    #
    # Asserted end to end through a real ask rather than by reaching for the
    # thunk, for the reason the parent-handle example above states: what matters
    # is that the tool Wiring hands the model finds the Agent Wiring built. A
    # spec that constructed its own thunk would pass while the shipped seam
    # stayed dead, which is exactly how the parent handle went unnoticed.
    it "hands the chat a session_usage tool reading the accounting of the Agent it built" do
      spending = Lain::Provider::Mock.new(
        responses: [Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }], stop_reason: :end_turn,
                                       usage: Lain::Usage.new(input_tokens: 11, output_tokens: 4))]
      )
      recorder, session = wiring.run_state(nil)
      agent = wiring.wire_agent(channel:, recorder:, session:,
                                backend: offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 },
                                                                   mock: spending))
      agent.ask("ping")

      report = agent.toolset.fetch("session_usage").call({}, nil)

      expect(report).to be_ok
      expect(report.content).to include("input: 11", "output: 4", "total: 15")
    end

    # The reason it is appended by ToolsetBuild rather than added to BaseTools:
    # a child attenuates from the floor, and the floor is built ONCE and shared,
    # so a thunk over the chat's Agent placed there would make every subagent
    # report its PARENT's spend as its own -- the same wrong answer, one
    # level down. The positive half is not decoration: `not_to include` alone
    # passes for a child attenuated to nothing, and would also pass while the
    # tool was never wired at all.
    it "keeps session_usage off the set a child attenuates from, so no child reports its parent's spend" do
      agent = wire_agent

      expect(agent.toolset.names).to include("session_usage")
      expect(agent.toolset.fetch("subagent").attenuates_from.names).not_to include("session_usage")
    end

    # Scenario: the toolset does not change with the mode
    #
    # Through the Agent a real Wiring built, so the claim is about the set the
    # model is really shown: a flip moves the gate, never the tool block a
    # prompt cache keys on. It reaches for the board the way
    # `approve_everything` below does, and for the same reason: the board is
    # Wiring's private collaborator, and the flip has to happen after
    # #wire_agent built and memoized it.
    it "renders the same tool block before and after /mode auto" do
      agent = wire_agent
      board = wiring.instance_variable_get(:@switchboard)
      before = [agent.toolset, agent.toolset.digest]

      board.mode_switch.switch(Lain::Mode.new(approval: :auto), surface: "spec")

      expect([agent.toolset, agent.toolset.digest]).to eq(before)
      expect(agent.toolset.names).to include("session_usage", "bash", "edit_file")
    end

    # The provider-reported window again, at the third construction site -- the
    # one a human actually reads. `Agent#occupancy` is asked with NO KEYWORD by
    # Frontend::PromptComposer::RunState, so the book has to have arrived when
    # the Agent was BUILT -- and this is the only place that happens.
    #
    # It is pinned here rather than by handing the same book to two objects and
    # comparing their arithmetic: that proves the division agrees and nothing
    # about the wiring. Deleting `context_window:` from Wiring#backing left
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
      expect(wiring.ask_human).to be_a(Lain::Tools::AskHuman)
      expect(wiring.questions).to be_a(Async::Queue)
      expect(wiring.supervisor).to be_a(Lain::Supervisor)
      expect(wiring.approvals).to be_a(Lain::Approval::Queue)
    end

    # The session Toolset is built ONCE (toolset_build.rb:61-64) and the
    # Agent holds it in an ivar for its whole life. This identity is what made a
    # #to_schema memo PLAUSIBLE -- Context#render (context.rb:162) calls
    # `toolset.to_schema` unconditionally every turn, against the same instance.
    # An earlier round declined that memo on a measurement (~225us per call,
    # orders of magnitude under a round trip) plus an objection: extra reachable
    # mutable state on a value object CLAUDE.md says must be deeply frozen.
    #
    # The memo shipped anyway, and both halves of that objection have since
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
    # {Lain::Agent::Instrumentation}, and a mutation run found that dropping
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

    # The run negotiates its Context's `#requires` against the provider it
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
    # default Context requires, and the assertion reads the journal
    # bytes rather than a policy object nobody injected.
    it "journals what the run's provider cannot give its context, once, under :degrade" do
      io = StringIO.new
      recording = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io:), journal_path: "wiring-spec.ndjson")
      lacking = Lain::Provider::Mock.new(responses: [Lain::Response.new(content: [], stop_reason: :end_turn)],
                                         capabilities: default_requires - %i[prompt_caching])
      recording_wiring = described_class.new(options: { grace: 5 }, chronicle: recording, status_feed:)
      recorder, session = recording_wiring.run_state(nil)
      recording_wiring.wire_agent(channel:, recorder:, session:,
                                  backend: offline_backend_class.new({ provider: "ollama", model: nil,
                                                                       max_tokens: 64 }, mock: lacking))

      degraded = io.string.each_line.map { |line| JSON.parse(line) }
                                    .select { |record| record["type"] == "capability_degraded" }
      expect(default_requires).to include(:prompt_caching)
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

      expect(default_requires.all? { |capability| mock_provider.supports?(capability) }).to be(true)
      expect(io.string).not_to include("capability_degraded")
    end

    # The surface is wired for every chat and answers to the board's
    # auto_approve layer, which --auto-approve starts on. Read through the
    # surface's own predicate, so a wiring that built the surface over some
    # other board would read the wrong layer here.
    it "wires an AutoSurface for every chat, engaged only when --auto-approve seeds the layer" do
      readings = [{ grace: 5 }, { grace: 5, auto_approve: true }].map do |options|
        wiring = described_class.new(options:, chronicle:, status_feed:)
        recorder, session = wiring.run_state(nil)
        wiring.wire_agent(channel:, recorder:, session:, backend:)
        wiring.auto_surface.instance_variable_get(:@enabled).call
      end

      expect(readings).to eq([false, true])
    end

    # No --secret-oracle, no surface. Asserted at the CONSTRUCTION
    # site as well as at the fan-out, because "a flag that wires nothing" and
    # "a capability with no reachable construction" are the same defect read
    # from opposite ends, and this chunk produced both.
    it "wires no secret surface without --secret-oracle" do
      wire_agent
      expect(wiring.secret_surface(backend)).to be_nil
    end

    describe "--secret-oracle" do
      let(:wiring) { described_class.new(options: { grace: 5, secret_oracle: true }, chronicle:, status_feed:) }

      before do
        recorder, session = wiring.run_state(nil)
        wiring.wire_agent(channel:, recorder:, session:, backend:)
      end

      it "constructs the triage surface" do
        expect(wiring.secret_surface(backend)).to be_a(Lain::Approval::SecretSurface)
      end

      it "memoizes it, so the Repl and any later reader share one surface and one journal fd" do
        expect(wiring.secret_surface(backend)).to be(wiring.secret_surface(backend))
      end

      # The whole point of the rung: even a run whose every provider knob names
      # a remote arm judges its parked secrets locally. Captured off the tier
      # the surface actually holds, not off a `.new` count.
      it "builds it against the LOCAL ollama provider, whatever --provider and --summarizer-provider say" do
        remote = { grace: 5, secret_oracle: true, provider: "anthropic", summarizer_provider: "anthropic" }
        built = described_class.new(options: remote, chronicle:, status_feed:)
        recorder, session = built.run_state(nil)
        built.wire_agent(channel:, recorder:, session:, backend:)

        tier = built.secret_surface(backend).instance_variable_get(:@oracle)
        # `.inner` peels {Lain::Provider::Journaled}, which wraps this provider
        # so the judge's own round trip reaches the Journal too. A
        # decorator cannot move the endpoint -- what it wraps is still the bare
        # local provider `SecretRead.tier` builds -- and this assertion is about
        # the endpoint.
        provider = tier.instance_variable_get(:@inner).instance_variable_get(:@provider).inner
        expect(provider).to be_a(Lain::Provider::Ollama)
      end

      # The judge's options come from the chat's Backend: a chat on the judge's
      # own local model shares its runner, so the batch size has to follow the
      # judge onto the wire or every judgement reloads the chat's model.
      it "hands the judge the chat's runner knobs when the chat runs the judge's own model" do
        tuned = offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64, num_batch: 2048 },
                                          mock: mock_provider)

        tier = wiring.secret_surface(tuned).instance_variable_get(:@oracle).instance_variable_get(:@inner)
        expect(tier.instance_variable_get(:@extra)).to eq("num_batch" => 2048)
      end
    end
  end

  # The flip a real Wiring's board journals, onto the run's own record.
  describe "a mode flip's journaled record" do
    let(:journal) { RecordingChannel.new }
    # See the note on wiring_spec's other recording examples: Chronicle#spool
    # derives the WAL path by pure string manipulation, and a Provider::Mock
    # run never writes a frame.
    let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "t1-modeswitch-spec-fake-session.ndjson") }

    def mode_switches = journal.events.grep(Lain::Telemetry::ModeSwitch)

    it "carries both axes on each side, and a gate flip beside it naming the ladder applied" do
      wire_agent
      board = wiring.instance_variable_get(:@switchboard)

      board.mode_switch.switch(Lain::Mode.new(approval: :auto), surface: "spec")

      flip = mode_switches.last
      expect(flip.to_h.slice(:from_scope, :from_approval, :to_scope, :to_approval))
        .to eq(from_scope: "checkout", from_approval: "ask", to_scope: "checkout", to_approval: "auto")
      expect(journal.events.grep(Lain::Telemetry::PolicySwitch).map(&:to)).to eq(["auto"])
    end
  end

  # The tool-phase guard was constructed bare (`RefuseSecretWrites.new`
  # with no `journal:`), so a live credential-shaped refusal journaled to
  # `Channel::Null` and left no record while every other mount of this
  # middleware (consolidation.rb, improve.rb, run_recorder.rb) passes one.
  describe "the secret-write guard's journal wiring" do
    # A tool turn primes the shadow snapshot store, which
    # lives under the state home -- so this chat gets a throwaway one.
    around do |example|
      Dir.mktmpdir("lain-wiring-state") do |state|
        @state = state
        example.run
      end
    end

    def credential_tool_use
      { "type" => "tool_use", "id" => "tu_1", "name" => "memory_write",
        "input" => { "id" => "creds", "description" => "oops", "body" => "sk-#{"a" * 20}" } }
    end

    let(:wiring) do
      described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                          paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }))
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

  # The guard's `oracle:` seam sat on its NullOracle in the live chat, so
  # the memory-save gate judged nothing there. Wiring it in composes the two
  # distinct findings: a credential is a PATTERN hit, a contentless save is
  # the oracle's DECLINE, and they must stay distinguishable in the journal.
  describe "the secret-write guard's oracle wiring" do
    # The same throwaway state home, for the same shadow snapshot store.
    around do |example|
      Dir.mktmpdir("lain-wiring-state") do |state|
        @state = state
        example.run
      end
    end

    let(:wiring) do
      described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                          paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }))
    end
    let(:journal) { RecordingChannel.new }
    # See the note above on journal_path: pure string manipulation derives the
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
        # The model-facing half: a decline must make no credential claim.
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

  # A streamed tool's bytes are a VIEW, not a record. Wiring hands
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
    # See the note above on journal_path: Chronicle#spool derives the WAL path by
    # pure string manipulation, and a Provider::Mock run never writes a frame.
    let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "t1-spec-fake-session.ndjson") }
    let(:views) { { channel: view_channel, socket_path: "/tmp/lain-t1-spec.sock", journal: } }
    # A throwaway state home: the bash turn primes the shadow
    # snapshot store, which lives there.
    let(:wiring) do
      described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                          paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }))
    end

    around do |example|
      Dir.mktmpdir("lain-wiring-state") do |state|
        @state = state
        example.run
      end
    end

    # Bash is tier 3 and would otherwise park on the approval gate forever;
    # this block is about where the bytes go, not who let them run. The
    # deleted `--yolo` flag used to buy that at construction, and `auto` is the
    # approval it resolved to -- so the board is flipped there instead. It has to happen HERE, after
    # #wire_agent, because that is where Wiring builds and memoizes the board,
    # and it reaches in for it because the board is Wiring's private
    # collaborator rather than part of its surface.
    def approve_everything
      wiring.instance_variable_get(:@switchboard)
            .mode_switch.switch(Lain::Mode.new(approval: :auto), surface: "spec")
    end

    def dispatch(attached)
      recorder, session = wiring.run_state(nil)
      agent = wiring.wire_agent(channel:, recorder:, session:, backend:, views: attached)
      approve_everything
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

  # Where the records a chat's collaborators write end up. The display Channel
  # renders three record types and skips the rest, so a record handed to it is
  # a record lost; these read the session record back instead.
  describe "the records a chat's collaborators write" do
    let(:session_io) { StringIO.new }
    let(:session_file) { Lain::Journal.new(io: session_io) }
    let(:chronicle) { Lain::CLI::Chronicle.new(journal: session_file, journal_path: "collaborator-records-session.ndjson") }
    let(:channel) { RecordingChannel.new }
    let(:mock_provider) do
      Lain::Provider::Mock.new(responses: [tool_response(["tu_bash", "bash", { "command" => "printf hello" }]),
                                           text_response("settled")])
    end
    let(:wiring) do
      described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                          paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }))
    end

    around do |example|
      Dir.mktmpdir("lain-wiring-records") do |state|
        @state = state
        example.run
      end
    end

    def records = session_io.string.each_line.map { |line| JSON.parse(line) }

    def of_type(type) = records.select { |record| record["type"] == type }

    # Bash is tier 3 and would park on the approval gate; the board is flipped
    # to `auto` after #wire_agent memoizes it, as the live-views group does.
    def converse(prompt)
      recorder, session = wiring.run_state(nil)
      agent = wiring.wire_agent(channel:, recorder:, session:, backend:)
      wiring.instance_variable_get(:@switchboard)
            .mode_switch.switch(Lain::Mode.new(approval: :auto), surface: "spec")
      agent.ask(prompt)
    end

    it "lands the bash tool's arm record for that call in the session record" do
      converse("run it")

      expect(of_type("shell_arm").map { |arm| arm["tool_use_id"] }).to eq(["tu_bash"])
    end

    # A chat launched without --nvim still tees onto the status feed whenever it
    # journals. The arm record is nothing that feed folds, so it must go round
    # the tee rather than through it.
    it "lands the arm record in the file and not on the status feed a plain chat tees" do
      feed = RecordingChannel.new
      Lain::CLI::LiveViews.new(options: { journal: true }, chronicle:, status_feed: feed)

      converse("run it")

      expect(of_type("shell_arm").size).to eq(1)
      expect(feed.events.grep(Lain::Telemetry::ShellArm)).to be_empty
    end

    context "when the model spawns a one-shot subagent" do
      let(:mock_provider) do
        Lain::Provider::Mock.new(responses: [tool_response(["s1", "subagent", { "prompt" => "look around" }]),
                                             text_response("child done"), text_response("parent done")])
      end

      def child_digests = of_type("child_turn").map { |turn| turn["digest"] }

      # A child's usage written as `turn_usage` would pair with the parent's
      # in-flight request in salvage, and be priced by the ledger as the
      # parent's spend.
      it "writes no turn_usage for a child turn, so salvage and the ledger see only the parent's" do
        converse("look around")

        expect([child_digests, of_type("turn_usage")]).to all(be_present)
        expect(of_type("turn_usage").map { |usage| usage["digest"] })
          .to match_array(of_type("turn").select { |turn| turn["role"] == "assistant" }.map { |turn| turn["digest"] })
        expect(child_digests.flat_map { |digest| Lain::Ledger::Index.from_journal(records).entries_for(digest) })
          .to be_empty
        expect(of_type("request_sent").size).to eq(of_type("turn_usage").size)
      end
    end
  end

  # The model phase's translator for a prompt the provider refused whole is
  # composed HERE, beside the turn phase's window refresh, and not inside the
  # chronicle's instrumentation: under --no-journal the chronicle has no model
  # stack at all, and a refused prompt is no less refused for going unrecorded.
  describe "the request budget a chat's model phase opens with" do
    # Ollama's own refusal, raised the way the provider raises it, for any
    # prompt carrying the marker.
    let(:refusing_provider) do
      Class.new(Lain::Provider::Mock) do
        def context_window_tokens(_model) = 32_768

        def complete(request, **)
          if JSON.generate(request.messages).include?("DOES-NOT-FIT")
            @requests << request
            raise Lain::Provider::Ollama::WindowExceededError.new(
              "request (80000 tokens) exceeds the available context size (32768 tokens)",
              prompt_tokens: 80_000, window_tokens: 32_768, source: "ollama", status: 400
            )
          end

          super
        end
      end.new(responses: [Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                             stop_reason: :end_turn)])
    end

    let(:served_backend) do
      offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: refusing_provider)
    end

    def asker(over: chronicle)
      wired = described_class.new(options: { grace: 5 }, chronicle: over, status_feed:)
      recorder, session = wired.run_state(nil)
      agent = wired.wire_agent(channel:, recorder:, session:, backend: served_backend)
      Lain::CLI::Repl::Ask.new(agent:, tty: nil, chronicle: over)
    end

    context "when the chat started with --no-journal" do
      it "ends the ask with the refusal naming the provider's numbers, and answers the next prompt" do
        ask = asker

        outcome = ask.attempt("DOES-NOT-FIT")

        expect(outcome).to be_a(Lain::Middleware::RequestBudget::OverWindow)
        expect(outcome.message).to include("80000", "32768", "/rewind")
        expect(ask.attempt("ping").text).to eq("settled")
        expect(refusing_provider.call_count).to eq(2)
      end
    end

    context "when the chat is journaling" do
      let(:journal_io) { StringIO.new }
      let(:recording) do
        Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io), journal_path: "budget-spec.ndjson")
      end

      def journaled(type)
        journal_io.string.each_line.map { |line| JSON.parse(line) }.select { |record| record["type"] == type }
      end

      it "records the refusal in the session record with the provider's exact figures" do
        asker(over: recording).attempt("DOES-NOT-FIT")

        expect(journaled("window_pressure"))
          .to contain_exactly(include("kind" => "over_window", "source" => "ollama", "prompt_tokens" => 80_000,
                                      "window_tokens" => 32_768))
      end
    end
  end

  # The assembly, and the point the whole chunk converges on. A plain `lain
  # chat` compacts, which means the Agent gets three things Wiring never passed
  # before: the run's per-turn Context source, the eager-summary observer its
  # ToolRunner fires through, and a journal that TEES turn_usage to that source
  # -- `context_for`'s `usage:` is a plain Integer, while {Lain::Compaction::Cold}
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
        def initialize(options, mock:, oracle:, root: Dir.pwd)
          super(options, root:)
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
    # The read turn primes the shadow snapshot store, which lives
    # under the state home -- this example's own tmpdir, not the developer's.
    let(:wiring) do
      described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                          paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @dir, "HOME" => @dir }))
    end

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
    # {Lain::Agent::Instrumentation} -- `fetch`, not `dig`, so a
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
      expect(agent.send(:tool_runner).instance_variable_get(:@observer)).to be(backend.tool_observer)
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

    # End to end: a tool result is offered to the summarizer, the
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

    # The control arm, on the SAME live path the flagged run below takes. The
    # flagged example alone would leave the default run's record free to carry
    # nil -- and nil is the one value {Lain::Telemetry::Compaction} reserves for
    # a journal written before this field existed, so a bench reading it would
    # drop the control arm's rows rather than compare against them. This
    # describe's own `compaction_options` set no `--compact-strategy`, which is
    # what makes this an unflagged launch and not a contrived one.
    it "journals the eager control arm on a run that named no strategy at all" do
      converse(wire_agent)

      accounting = journal.events.grep(Lain::Telemetry::Compaction)
      expect(accounting).not_to be_empty
      expect(accounting.map(&:collapse_strategy).uniq).to eq([Lain::Telemetry::Compaction::EAGER_CONTROL_ARM])
    end

    # End to end, and the only place the whole thread is real: the flag is
    # parsed here, {Lain::CLI::Backend::SpanSummarizer} resolves it, the Source
    # carries the operator's word, and the Scheduler -- handed a pipeline, able
    # to name no policy behind it -- journals that word on every compaction. It
    # is what lets a bench group `bytes_before - bytes_after` by arm with no
    # launch command to hand.
    context "with --compact-strategy" do
      let(:compaction_options) { super().merge(compact_strategy: "elide-tools") }

      it "journals the arm the operator named on every compaction it performs" do
        converse(wire_agent)

        accounting = journal.events.grep(Lain::Telemetry::Compaction)
        expect(accounting).not_to be_empty
        expect(accounting.map(&:collapse_strategy).uniq).to eq(["elide-tools"])
      end
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

  # `--isolation`, wired at the ONE seam the fleet leases through. The main
  # chat is deliberately NOT leased -- #run_state builds its Session on
  # {Lain::WorkerEnv.default}, because the user's own edits belong in the user's
  # own tree -- so what a leased environment reaches is an ACTOR-mode subagent,
  # adopted through this Supervisor.
  describe "the fleet's isolation backend" do
    require "fileutils"
    require "mixlib/shellout"
    require "tmpdir"

    # The lease and handback records land in the session record, read back here
    # off a recording journal. The display Channel is recorded too, only so
    # nothing blocks on a SizedQueue nobody drains.
    let(:channel) { RecordingChannel.new }
    let(:record) { RecordingChannel.new }
    let(:chronicle) { Lain::CLI::Chronicle.new(journal: record, journal_path: "fleet-isolation-session.ndjson") }

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

    def leases = record.events.grep(Lain::Telemetry::IsolationLease)

    # A chat started somewhere OTHER than the repo this suite runs in, so "the
    # lease names the chat's own cwd" is an assertion and not a coincidence --
    # and so no `.lain/services.rb` of the host project can decorate the backend.
    def in_throwaway_chat_dir(&block)
      Dir.mktmpdir("lain-d2-chat") { |dir| Dir.chdir(File.realpath(dir), &block) }
    end

    # ONE backend per run, and the run's two consumers share it. The fleet a
    # {Lain::Supervisor} adopts actors onto and the children a model dispatches
    # both key resources on a worker id, and both allocate from per-INSTANCE
    # state -- {Lain::Isolation::Worktree}'s `@leased` Set and Monitor serialize
    # one instance, so two backends cannot refuse each other's paths, and a
    # per-{Lain::Isolation::DbIndex} pool hands the same index out twice. The
    # declaration file is read once for the same reason
    # {Lain::CLI::IsolationBackend}'s own `#services` gives.
    #
    # Resolution count is the whole assertion available without a reader: with
    # exactly one resolved, the example below (the supervisor leasing a real
    # Worktree) and the model-dispatch example (the child leasing a real
    # Worktree) cannot be naming two different objects.
    it "resolves ONE isolation backend for the whole run, not one per consumer" do
      allow(Lain::CLI::IsolationBackend).to receive(:resolve).and_call_original

      in_throwaway_chat_dir do
        wiring = wiring_with(nil)
        recorder, session = wiring.run_state(nil)
        wiring.wire_agent(channel:, recorder:, session:, backend:)
      end

      expect(Lain::CLI::IsolationBackend).to have_received(:resolve).once
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

      # No checkout was cut, so there is nothing to hand back -- and a handback
      # run over the chat's OWN tree would read the human's work as a worker's.
      it "runs no handback when the fleet cuts no checkout to hand back from" do
        in_throwaway_chat_dir do
          wiring = wiring_with(nil)
          recorder, session = wiring.run_state(nil)
          wiring.wire_agent(channel:, recorder:, session:, backend:)
          Sync { wiring.role_spawn.call(:dev, :fresh, "work") }
        end

        expect(record.events.grep(Lain::Telemetry::Handback)).to be_empty
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
            Dir.mktmpdir("lain-d2-state") do |state|
              xdg = { "XDG_RUNTIME_DIR" => File.realpath(runtime), "XDG_STATE_HOME" => File.realpath(state) }
              Dir.chdir(repo) { with_env(xdg) { yield repo, xdg["XDG_STATE_HOME"] } }
            end
          end
        end
      end

      it "hands the supervisor the resolved worktree backend" do
        in_throwaway_repo { adopt_worker(wiring_with("worktree")) }

        expect(leases.map(&:backend).uniq).to eq(["Lain::Isolation::Worktree"])
      end

      # THROUGH THE TOOL, and that is the whole of why this example exists. The
      # defect it pins survived because every spec that proved a lease injected
      # its own backend, while production threaded {Lain::WorkerEnv.default}
      # down #run_child -- so a proof over an injected backend would have
      # shipped the same gap a second time, green. Nothing here is doubled: the
      # backend is the one `--isolation worktree` really resolves, the tool is
      # the one this run's own ToolsetBuild built, and the spawn is a tool_use
      # the model dispatched through the parent's loop.
      #
      # A child's cwd is unobservable from outside a spawn that hands back a
      # Timeline and never an Agent, so the child asks for a RELATIVE path that
      # does not exist and `list_files` names the absolute path it resolved to.
      context "when the MODEL dispatches a subagent" do
        let(:mock_provider) do
          Lain::Provider::Mock.new(responses: [
                                     tool_response(["s1", "subagent", { "prompt" => "look around" }]),
                                     tool_response(["l1", "list_files", { "path" => "no-such-dir" }]),
                                     text_response("child done"),
                                     text_response("parent done")
                                   ])
        end

        def spawn_through_the_tool(wiring)
          recorder, session = wiring.run_state(nil)
          agent = wiring.wire_agent(channel:, recorder:, session:, backend:)
          Sync { agent.ask("look around") }
        end

        # The one tool_result whose content is a refusal naming an absolute
        # path: the child's `list_files` at a relative path that is nowhere.
        def child_resolved_path
          refusal = mock_provider.requests.flat_map(&:messages)
                                 .flat_map { |message| message["content"] }
                                 .grep(Hash)
                                 .find { |block| block["type"] == "tool_result" }
          refusal.fetch("content").to_s.delete_prefix("no such directory: ")
        end

        it "leases the resolved worktree for the child, which resolves its relative paths there" do
          chat_cwd = nil
          runtime_dir = nil
          in_throwaway_repo do |repo, runtime|
            chat_cwd = repo
            runtime_dir = runtime
            spawn_through_the_tool(wiring_with("worktree"))
          end

          expect(leases.map { |lease| [lease.kind, lease.backend] })
            .to eq([[:acquired, "Lain::Isolation::Worktree"], [:released, "Lain::Isolation::Worktree"]])
          # Under the throwaway XDG_STATE_HOME -- its own dir, apart from the
          # runtime dir -- and NOT under the chat's own tree.
          expect(child_resolved_path).to start_with(runtime_dir)
          expect(child_resolved_path).to include("/worktrees/")
          expect(child_resolved_path).not_to start_with(chat_cwd)
        end
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

      # The chat path's handback: a one-shot child's lease ends in the run's
      # WorkerHandoff, onto the branch the chat launched on, with the strategy
      # the project's `[isolation]` table names -- and the Supervisor holds the
      # same handoff, so a crashed actor's commits are anchored rather than
      # kept by nothing.
      describe "the handback a worker's work comes home through" do
        def git_out(dir, *args)
          shell = Mixlib::ShellOut.new("git", "-C", dir, *args,
                                       environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
          shell.run_command.error!
          shell.stdout.strip
        end

        def on_feat(repo, config: nil)
          git_out(repo, "switch", "-q", "-c", "feat")
          return if config.nil?

          FileUtils.mkdir_p(File.join(repo, ".lain"))
          File.write(File.join(repo, ".lain", "config.toml"), config)
        end

        def spawn_dev(wiring, notice: ->(_line) {})
          recorder, session = wiring.run_state(nil)
          wiring.wire_agent(channel:, recorder:, session:, backend:, notice:)
          Sync { wiring.role_spawn.call(:dev, :fresh, "work") }
        end

        def handbacks = record.events.grep(Lain::Telemetry::Handback)

        it "hands a one-shot child's lease back with the strategy the project's config names" do
          in_throwaway_repo do |repo|
            on_feat(repo, config: %([isolation]\nconflict_style = "diff3"\n))
            spawn_dev(wiring_with("worktree"))
          end

          expect(handbacks.map(&:strategy)).to eq(["conflict_style=diff3 diff_algorithm=histogram"])
        end

        it "syncs each child with the rebase retries the project's config names" do
          in_throwaway_repo do |repo|
            on_feat(repo, config: %([isolation]\nrebase_retries = 0\n))
            spawn_dev(wiring_with("worktree"))
          end

          expect(handbacks.map(&:sync)).to eq([:disabled])
        end

        # Memoized, so whichever caller came first would decide which notice a
        # broken table is told through: every caller names it instead.
        it "is built with the notice every caller hands it, never an order-dependent default" do
          # The KINDS, not the names: what matters is that nothing is optional,
          # since an optional notice is what would let the first caller decide.
          # Asserting the spelling too reddened this on a rename.
          expect(described_class.instance_method(:handback).parameters.map(&:first)).to eq([:req])
        end

        it "tells the human a malformed [isolation] table was ignored, and hands back with lain's defaults" do
          notices = []
          in_throwaway_repo do |repo|
            on_feat(repo, config: %([isolation]\nconflict_style = "wavy"\n))
            spawn_dev(wiring_with("worktree"), notice: ->(line) { notices << line })
          end

          expect(notices).to include(a_string_matching(/\[isolation\].*lain's defaults.*conflict_style/m))
          expect(handbacks.map(&:strategy)).to eq(["conflict_style=zdiff3 diff_algorithm=histogram"])
        end

        it "anchors a crashed actor's commits when the supervisor stops, instead of keeping nothing" do
          anchored = nil
          worker = in_throwaway_repo do |repo|
            on_feat(repo)
            wiring = wiring_with("worktree")
            recorder, session = wiring.run_state(nil)
            wiring.wire_agent(channel:, recorder:, session:, backend:)
            crashed = Sync do |task|
              wiring.supervisor.run(task)
              wiring.supervisor.adopt(role: "dev") { |worker_env| WiringSpecCrashedWorker.new(worker_env) }
            ensure
              wiring.supervisor.stop
            end
            anchored = git_out(repo, "for-each-ref", "--format=%(objectname)", "refs/lain/worker/")
            crashed
          end

          expect(anchored).to eq(worker.commit)
        end

        # The handoff is built before the toolset, and its resolver is the
        # toolset's RoleSpawn -- read late, through a thunk, so the run still
        # constructs exactly one.
        it "builds one RoleSpawn for the run, which the handoff's resolver reads late" do
          allow(Lain::Skill::RoleSpawn).to receive(:new).and_call_original

          in_throwaway_repo do |repo|
            on_feat(repo)
            wiring = wiring_with("worktree")
            recorder, session = wiring.run_state(nil)
            wiring.wire_agent(channel:, recorder:, session:, backend:)
          end

          expect(Lain::Skill::RoleSpawn).to have_received(:new).once
        end
      end
    end

    # The sibling of the block below, at the seam a COMMAND becomes a process
    # rather than the one a WORKER leases an environment from, and it keeps the
    # same ordering rule: resolved before the header is pinned.
    context "with an unrecognized exec option" do
      it "raises a Lain::Error before the toolset exists" do
        wiring = described_class.new(options: { grace: 5, exec: "podman" }, chronicle:, status_feed:)
        recorder, session = wiring.run_state(nil)

        expect { wiring.wire_agent(channel:, recorder:, session:, backend:) }
          .to raise_error(Lain::Error, /unknown exec backend "podman".*local.*docker/m)
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
          # "No session record behind" is now literal. A journal that
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

    # The injection seams: a spec assembles and runs the whole conversation
    # through #run's own path -- no send(:build_repl), no instance_variable_set
    # -- by handing in a StringIO-backed TTY factory and a recording conductor
    # opener instead of the real-terminal defaults.
    let(:opened) { [] }
    let(:conductor_opener) { ->(**kwargs) { Lain::CLI::Conductor.open(**kwargs).tap { |c| opened << c } } }

    # Wiring hands the factory a `prompt_renderer:` too. It is swallowed rather
    # than forwarded: what this spec is about is the object WIRING composes and
    # passes on, not what the TTY then does with it (that is tty_spec's).
    def tty_factory(dir)
      lambda do |channel:, **|
        Lain::Frontend::TTY.new(channel:, output: StringIO.new, history_path: File.join(dir, "history"))
      end
    end

    def run_wiring(input: "quit\n", options: { grace: 5 })
      Dir.mktmpdir do |dir|
        wiring = described_class.new(options:, chronicle:, status_feed:, stdin: StringIO.new(input),
                                     tty_factory: tty_factory(dir), conductor_opener:)
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
        wiring
      end
    end

    # The epic driver's supervisor, retirement and landing queue all journal
    # into what these seams carry, and a chat can only reach that driver through
    # a slash command, so nothing else here would notice a display Channel there.
    it "hands the epic driver's seams the session record, never the display channel" do
      allow(Lain::CLI::EpicDriver::Seams).to receive(:new).and_call_original

      run_wiring

      expect(Lain::CLI::EpicDriver::Seams).to have_received(:new)
        .with(hash_including(journal: be(chronicle.durable_journal)))
    end

    # `--input socket:<name>` puts the human in another pane. The chat then has
    # no reader for its own stdin at all, which is the point: a `lain up` chat
    # pane is a scrolling transcript nobody types into.
    it "reads the human from an input socket, never this terminal, when --input names one" do
      Dir.mktmpdir do |dir|
        paths = Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => dir })
        path = Lain::CLI::InputSocket.path(name: "wiring", paths:, cwd: Dir.pwd)
        stdin = StringIO.new("never read\n")
        allow(status_feed).to receive(:state).and_return({})
        wiring = described_class.new(options: { grace: 5, input: "socket:wiring" }, chronicle:, status_feed:,
                                     paths:, stdin:, tty_factory: tty_factory(dir), conductor_opener:)
        pane = Thread.new { end_the_chat_from_a_pane(path) }

        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)

        expect([pane.value, stdin.pos]).to eq([path, 0])
      end
    end

    # History is a line editor's, and a chat reading a pipe has none: what a
    # script feeds it is not what a human would reach for at `you>`.
    it "keeps no history for a chat reading a stream that is not a terminal" do
      kept = Dir.mktmpdir do |dir|
        wiring = described_class.new(options: { grace: 5 }, chronicle:, status_feed:, stdin: StringIO.new("quit\n"),
                                     tty_factory: tty_factory(dir), conductor_opener:)
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
        File.exist?(File.join(dir, "history"))
      end

      expect(kept).to be(false)
    end

    # The pane is a line editor in another process, and its lines reach the
    # chat's Intake over the socket -- which is where they are kept, so a
    # cockpit's history is the chat's and not the pane's.
    it "keeps the line a pane sent over the input socket in the chat's history" do
      Dir.mktmpdir do |dir|
        paths = Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => dir })
        path = Lain::CLI::InputSocket.path(name: "wiring-history", paths:, cwd: Dir.pwd)
        allow(status_feed).to receive(:state).and_return({})
        wiring = described_class.new(options: { grace: 5, input: "socket:wiring-history" }, chronicle:, status_feed:,
                                     paths:, stdin: StringIO.new, tty_factory: tty_factory(dir), conductor_opener:)
        pane = Thread.new { type_at_you_from_a_pane(path, "quit") }

        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
        pane.join

        expect(File.read(File.join(dir, "history"))).to eq("quit\n")
      end
    end

    # Answers the first `you>` a pane is shown with `text`, as a human typing
    # there would, then goes away.
    def type_at_you_from_a_pane(path, text)
      client = Enumerator.produce { connect_to(path) }.lazy.grep(UNIXSocket).first
      prompt = Enumerator.produce { JSON.parse(client.gets) }.find { |frame| frame["kind"] == "you" }
      client.write("#{JSON.generate({ "v" => "line", "text" => text, "generation" => prompt["generation"] })}\n")
      client.flush
      client.read
    ensure
      client&.close
    end

    # Connects as a `lain input` pane would, waits for a frame, and ends the
    # stream. Answers the path it reached, so the assertion names the socket
    # that was there rather than a bare true.
    def end_the_chat_from_a_pane(path)
      client = Enumerator.produce { connect_to(path) }.lazy.grep(UNIXSocket).first
      client.gets
      client.write(%({"v":"eof"}\n))
      client.flush
      path
    end

    def connect_to(path)
      UNIXSocket.new(path)
    rescue SystemCallError
      sleep(0.01)
      nil
    end

    it "threads the injected tty/conductor seams -- the conductor the opener built is the one exposed" do
      wiring = run_wiring

      expect(opened).to eq([wiring.conductor])
    end

    # What replaced the desktop notifier as `request_review`'s way of telling a
    # human a file is waiting on them -- and with no editor wired in production
    # ({CLI::EpicMount#request_review} says why), the only way. Asserted through
    # the object rather than through a keyword: the seam is a thunk read at CALL
    # time, so the question is what it reaches once a frontend exists.
    describe "the run's one line to the human" do
      it "says nothing before a frontend exists, which is the window the toolset is built in" do
        wiring = described_class.new(options: { grace: 5 }, chronicle:, status_feed:)

        expect { wiring.told.call("a file is waiting") }.not_to raise_error
      end

      it "reaches the terminal once #run has built one" do
        rendered = StringIO.new
        Dir.mktmpdir do |dir|
          factory = lambda do |channel:, **|
            Lain::Frontend::TTY.new(channel:, output: rendered, history_path: File.join(dir, "history"))
          end
          wiring = described_class.new(options: { grace: 5 }, chronicle:, status_feed:, stdin: StringIO.new("quit\n"),
                                       tty_factory: factory, conductor_opener:)
          wiring.run(backend:, resumed: nil, nvim: nil)
          wiring.conductor.close(reason: :exit)
          wiring.told.call("epic.md is open for review")
        end

        expect(rendered.string).to include("epic.md is open for review")
      end
    end

    # The ONE production line the fix rests on. {Lain::StatusFeed} is built
    # a layer above this class ({Lain::CLI::ChatLaunch}, which must have it
    # in the live-view tee's sink list before Wiring exists), so it holds no
    # Store at construction and its inbox_count can retire nothing until this
    # class hands it one. Nothing else observes that hand-over: deleting it left
    # every example in this file green while the HUD went back to counting up
    # forever, which is the defect class this card exists to remove. So the call
    # is EXPECTED here, and against the run's own Store -- an `instance_of`
    # would still pass for a second, empty one, which retires exactly nothing.
    it "hands the StatusFeed the run's own Store, the only thing that lets inbox_count retire" do
      wiring = run_wiring

      expect(status_feed).to have_received(:bind_store).with(wiring.command_surface.env.agent.timeline.store)
    end

    # The Conductor is the ONE place a user prompt is answered, so it is
    # where RunClock#record_input is called -- and the clock it records on has
    # to be the one the StatusFeed publishes, or the published idle never
    # resets. ChatLaunch builds it; this class only has to pass it on.
    it "passes the run's RunClock on to the conductor it opens" do
      run_clock = Lain::RunClock.new
      seen = []
      opener = ->(**kwargs) { Lain::CLI::Conductor.open(**kwargs).tap { seen << kwargs[:run_clock] } }

      Dir.mktmpdir do |dir|
        wiring = described_class.new(options: { grace: 5 }, chronicle:, status_feed:, run_clock:,
                                     tty_factory: tty_factory(dir), stdin: StringIO.new("quit\n"),
                                     conductor_opener: opener)
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
      end

      expect(seen).to eq([run_clock])
    end

    # {Lain::CLI::Wiring#goal_journal} (wiring.rb:334) resolves the standing-goal
    # driver's destination through {Lain::CLI::Chronicle#record_journal}. Nothing
    # asserted it: replacing the resolution with a fresh /dev/null Journal left
    # the ENTIRE suite green (a mutant that survived), because every other
    # example here runs over Chronicle::Null, whose record_journal IS a discard
    # -- so a discard substituted for a discard changed nothing observable
    # anywhere. This one records, and drives the real driver the run wired.
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
                                       tty_factory: tty_factory(dir), stdin: StringIO.new("quit\n"), conductor_opener:)
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

    # `--no-journal --nvim`: no session record, and every journal-role
    # collaborator is handed the tee onto nvim's own journal. A flip there must
    # apply whole -- gate policy and all -- and a goal must drive, where a tee
    # that answered only `<<` killed the chat on the first `record`.
    context "with a --no-journal chronicle teed onto an editor's journal" do
      let(:tee_io) { StringIO.new }
      let(:chronicle) do
        Class.new(Lain::CLI::Chronicle::Null) do
          def initialize(tee)
            super()
            @tee = tee
          end
        end.new(Lain::CLI::JournalTee.new(Lain::Journal.new(io: tee_io), Lain::Channel::DropOldest.new))
      end

      def settled_with(text)
        Lain::Timeline.empty.commit(role: :user, content: [{ "type" => "text", "text" => "go" }])
                      .commit(role: :assistant, content: [{ "type" => "text", "text" => text }])
      end

      # Scenario: a switch applies wholly under --no-journal --nvim
      it "applies /mode auto to the gate and drives /goal, with no NoMethodError" do
        Dir.mktmpdir do |dir|
          wiring = described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                                       tty_factory: tty_factory(dir), stdin: StringIO.new("quit\n"), conductor_opener:)
          wiring.run(backend:, resumed: nil, nvim: nil)
          commands = wiring.command_surface.commands

          commands.dispatch("/mode auto") { raise "unmatched" }
          commands.dispatch("/goal ship it") { raise "unmatched" }
          prompt = wiring.command_surface.goal_driver.poll(settled_with("working on it"))
          wiring.conductor.close(reason: :exit)

          expect(wiring.instance_variable_get(:@switchboard).policy_switch.current.map(&:name))
            .to eq(%w[triage rules auto])
          expect(prompt).to include("ship it")
        end

        types = tee_io.string.each_line.map { |line| JSON.parse(line)["type"] }
        expect(types).to include("mode_switch", "goal_iteration")
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

    # The load-bearing identity behind it (a review panel's probe): a dropped
    # surface_kwargs would leave this reader on its Null and silently
    # disconnect /model from the Agent's Context.
    it "hands the Env the SAME model switch the Agent's context holds" do
      wiring = run_wiring
      env = wiring.command_env

      expect(env.model_switch).to be_a(Lain::Context::ModelSwitch)
      expect(env.agent.context.model).to eq(env.model_switch.current)
      env.model_switch.switch("probe-model-x", surface: "probe")
      expect(env.agent.context.model).to eq("probe-model-x")
    end

    # The session's ONE queue, pinned on the {Lain::CLI::Switchboard} because
    # that is what owns the policy switch: the gate policy is DERIVED from a
    # mode flip (#apply writes it as the consequence of the flip /mode reaches
    # through `mode_switch`), so no command reads it and Command::Env no longer
    # carries it. What the Gate holds is the LADDER, and the identity that
    # matters is one rung down -- its asking rung must park on the same object
    # /approve drains, or a rewiring gives the run two queues and the drain
    # empties the wrong one.
    #
    # Reached for privately, on the same terms as `board_for` below: the board
    # IS this run's authority and nothing in lib/ asks Wiring for it, so a
    # public reader would exist only for this example.
    it "parks the ladder's asking rung on the SAME queue /approve drains" do
      wiring = run_wiring
      board = wiring.instance_variable_get(:@switchboard)

      expect(board.policy_switch).to be_a(Lain::Approval::PolicySwitch)
      expect(board.policy_switch.current).to be_a(Lain::Approval::Escalation)
      expect(board.policy_switch.current.find { |rung| rung.name == "surfaces" }.queue).to be(wiring.approvals)
      # The queue /approve actually drains, reached the way the command does.
      expect(wiring.command_env.approvals).to be(wiring.approvals)
    end

    # BEFORE the threading below, a wired session read the project tree FIVE
    # times -- two Skill::Catalog loads (the command Surface's, and the one
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

      # The pair had TWO owners -- Wiring loaded the catalog, Backend the
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
      # reads of the project tree originally, two after the threading (one per
      # owner), and one apiece now. Identity alone would still pass if some
      # reader loaded a snapshot it then threw away, so the count is its own
      # assertion.
      it "loads the catalog exactly once and the slots exactly once for the whole session" do
        allow(Lain::Skill::Catalog).to receive(:load).and_call_original
        allow(Lain::Prompt::Slots).to receive(:load).and_call_original

        run_wiring

        expect(Lain::Skill::Catalog).to have_received(:load).once
        expect(Lain::Prompt::Slots).to have_received(:load).once
      end
    end

    it "wires the queue-shaped NoApprovals under --non-interactive, so the env reader stays nil-free" do
      wiring = run_wiring(options: { grace: 5, non_interactive: true })

      expect(wiring.command_env.approvals).to be(Lain::CLI::Command::Env::NoApprovals)
    end

    # This class is the only object holding the Agent, the RunClock and
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
      def recording_factory(dir, seen)
        lambda do |channel:, **kwargs|
          seen << kwargs[:prompt_renderer]
          tty_factory(dir).call(channel:)
        end
      end

      def run_recording(options: { grace: 5 }, &notice)
        seen = []
        Dir.mktmpdir do |dir|
          wiring = described_class.new(options:, chronicle:, status_feed:,
                                       tty_factory: recording_factory(dir, seen), conductor_opener:,
                                       stdin: StringIO.new("quit\n"))
          wiring.run(backend:, resumed: nil, nvim: nil, &notice)
          wiring.conductor.close(reason: :exit)
        end
        seen
      end

      it "hands the TTY factory a renderer composed from the run's own state" do
        expect(run_recording.first).to be_a(Lain::Frontend::PromptComposer::Formatted)
      end

      # Through the wiring rather than in isolation: the renderer this
      # class built reads the LIVE agent, so the model it names is the one the
      # run is actually talking to.
      it "builds it over the live model slot, the run clock and the status feed" do
        composed = run_recording.first.call(text: "> ", theme: plain_theme)

        expect(composed).to include(Lain::Provider::Ollama::DEFAULT_MODEL)
        expect(composed.lines.last).to eq("> ")
      end

      # The modes chunk wired the live switch and the shipped format's $mode
      # segment both; what never happened is THIS class handing the RunState the
      # switch to read. `checkout ask` is where a session starts and its lighters
      # are the empty String on purpose (default.toml's own note), so a chat that
      # never flips renders exactly as it did before this card -- the honest
      # reading is "nothing to say", not a literal word on the line. A flip is
      # where the wiring becomes observable: the SAME renderer, called again,
      # reads the switchboard's live slot and the chrome changes with it.
      it "wires the run's live mode switch into the prompt, so a mode flip shows at the next render" do
        agent = wire_agent
        board = wiring.instance_variable_get(:@switchboard)
        renderer = wiring.send(:prompt_renderer, agent, nil)

        before_flip = renderer.call(text: "> ", theme: plain_theme)
        expect(before_flip).not_to include("AUTO")

        board.mode_switch.switch(Lain::Mode.new(approval: :auto), surface: "spec")
        after_flip = renderer.call(text: "> ", theme: plain_theme)

        expect(after_flip).to include("AUTO")
      end

      # The object identity behind the render above: the state the renderer was
      # BUILT with already names the switchboard's own mode_switch, not a copy
      # taken at construction time -- reached directly so this example fails for
      # the wiring reason rather than for a rendering or elision one.
      it "hands the RunState the switchboard's own mode_switch object" do
        agent = wire_agent
        board = wiring.instance_variable_get(:@switchboard)
        renderer = wiring.send(:prompt_renderer, agent, nil)
        state = renderer.instance_variable_get(:@state)

        expect(state.instance_variable_get(:@mode)).to be(board.mode_switch)
        expect(state.instance_variable_get(:@mode).current).to eq(Lain::Mode.new)
      end

      # A project config that does not parse is reported through the same
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

    # The `vi` and `notify` layers are the terminal's to act on, so what this
    # class owes the TTY factory is the session's layer set as it is NOW --
    # read through the live switch `/mode` writes, never a copy taken at launch.
    describe "the mode layers the terminal reads" do
      def layered_factory(rendered, dir, seen)
        lambda do |channel:, layers:, **|
          seen << layers
          Lain::Frontend::TTY.new(channel:, output: rendered, layers:, history_path: File.join(dir, "history"),
                                  tmux: ->(_note) {})
        end
      end

      def run_layered(rendered = StringIO.new, seen = [])
        Dir.mktmpdir do |dir|
          wiring = described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                                       tty_factory: layered_factory(rendered, dir, seen), conductor_opener:,
                                       stdin: StringIO.new("quit\n"))
          wiring.run(backend:, resumed: nil, nvim: nil)
          yield wiring
          wiring.conductor.close(reason: :exit)
        end
        seen
      end

      def type_mode(wiring, args) = Lain::CLI::Command::Mode.new.call(args, wiring.command_env)

      it "hands the factory a reading of the layers that follows /mode" do
        seen = run_layered do |wiring|
          type_mode(wiring, "+vi")
        end

        expect(seen.size).to eq(1)
        expect(seen.first.call).to include(:vi)
      end

      it "hands it a reading that shows a layer lowered again" do
        seen = run_layered do |wiring|
          type_mode(wiring, "+vi +notify")
          type_mode(wiring, "-vi")
        end

        expect(seen.size).to eq(1)
        expect(seen.first.call.names).to eq([:notify])
      end

      # The review half of the notify layer: `request_review`'s line to the
      # human is a summons, so it rings while the layer is up.
      it "rings the terminal with the run's line to the human once /mode +notify is typed" do
        rendered = StringIO.new

        run_layered(rendered) do |wiring|
          wiring.told.call("quiet before the layer")
          type_mode(wiring, "+notify")
          wiring.told.call("epic.md is open for review")
        end

        expect(rendered.string.count("\a")).to eq(1)
        expect(rendered.string.index("\a")).to be > rendered.string.index("epic.md is open for review")
      end
    end

    # request_review is a capability, so it is the toolset build's to
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
                                     tty_factory: tty_factory(dir), stdin: StringIO.new("quit\n"), conductor_opener:)
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

      # `/implement-epic` drives the SAME mount the tool and the editor read.
      # The seat resolves it once, and the driver is built from that one mount:
      # a second EpicMount.for would hand this chat a second Epic::Review over
      # one journal, which stops guarding silently.
      it "builds the command surface's epic driver from the seat's one mount" do
        in_project("alpha") do |dir|
          driver = run_in(dir).command_env.epic_driver

          expect(driver).to be_mounted
          expect(driver.slug).to eq("alpha")
        end
      end

      # No epic resolved costs the chat its driver exactly as it costs it the
      # tool -- and what it gets instead is the refusing Null, never nil.
      it "hands it the refusing Null when no epic resolves, so the command still answers" do
        in_project("alpha", "beta") do |dir|
          expect(run_in(dir).command_env.epic_driver).not_to be_mounted
        end
      end

      # THE REASON THIS GROUP NEEDED MORE THAN IT HAD. This wiring
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

  # The run's {Lain::Project}, threaded. Five collaborators used to reach
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
                                     tty_factory: project_tty_factory(dir), stdin: StringIO.new("quit\n"))
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
        wiring
      end
    end

    def project_tty_factory(dir)
      lambda do |channel:, **|
        Lain::Frontend::TTY.new(channel:, output: StringIO.new, history_path: File.join(dir, "history"))
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
    it "hands the isolation and exec backends, epic mount, review seams and command surface the ROOT" do
      allow(Lain::CLI::IsolationBackend).to receive(:resolve).and_call_original
      allow(Lain::CLI::ExecBackend).to receive(:resolve).and_call_original
      allow(Lain::CLI::EpicMount).to receive(:for).and_call_original
      allow(Lain::CLI::ReviewSeams).to receive(:for).and_call_original
      allow(Lain::CLI::Command::Surface).to receive(:new).and_call_original

      in_project_tree do |root, cwd|
        run_project(project_at(root, cwd))

        expect(Lain::CLI::IsolationBackend).to have_received(:resolve).with(anything, hash_including(root:))
        expect(Lain::CLI::ExecBackend).to have_received(:resolve).with(anything, hash_including(root:))
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

    # With nothing injected the default resolves the process's own
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
      # does -- the review demonstrated it: replacing #default_project's body
      # with `Project.new(root: Dir.pwd, cwd: Dir.pwd, ...)` reverted the whole
      # change at its one production entry point and left every delivered example
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

  # Every OTHER spec of this boundary passes by handing a classifier in,
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

    # `HOME` is injected at the tmpdir base for the reason the project-walk group
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
          .to raise_error(Lain::Config::Refusal,
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

        expect { wired(root:, chronicle: spy) }
          .to raise_error(Lain::Config::Refusal, /\[sensitivity\] must be a table/)
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

    # The ruling at the session: the strict compile is the sensitivity table's
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

    # The child's half of the same wiring: the seam's tool stack is built over
    # the board, so a subagent's gate asks THIS classifier. It answered the
    # Null's false until the board held a real one.
    it "hands the same classifier to the subagent seam" do
      in_tree do |root|
        child_gate = wired(root:).send(:toolset_build).send(:seam).tool_middleware
                                 .call(Lain::WorkerEnv.default).to_a.last

        expect(child_gate.instance_variable_get(:@sensitivity).gates?(read_of(File.join(root, ".env")))).to be(true)
      end
    end

    # The other object a real chat's board is built from, and the only one it
    # SHARES with the toolset: {Wiring#verdict} is memoized, so #build_toolset
    # and #switchboard read one slot and the bash tool and the ladder's triage
    # rung end up holding one {Lain::Shell::Verdict}. That is what makes "the
    # journalled verdict is the verdict the tool acted on" true by
    # construction -- nothing is carried between the gate and the tool, so
    # nothing can be forged in transit either.
    describe "the shell verdict a real chat builds" do
      def verdict_of_rung(board) = board.ladder.first.instance_variable_get(:@verdict)

      def verdict_of_tool(board) = board.toolset.fetch("bash").instance_variable_get(:@verdict)

      # `equal?` and never `eq`, because identity is the CLAIM: one object at
      # two seams, so nothing has to be carried between the gate and the tool.
      # `eq` would assert something weaker and different -- that two verdicts
      # agree -- which is exactly what the regression this guards against
      # produces ({ToolsetBuild} and {BoardBuild} each calling
      # `Shell::Verdict.new`, restoring the double parse with a green suite).
      #
      # `eq` happens to catch it TODAY, and only by coincidence of two
      # unrelated classes inheriting `Object#==`. Measured:
      # `Verdict.new == Verdict.new` and `Parse.new == Parse.new` are both
      # false, while `Exclusions` is a `Data` and already compares equal. The
      # coincidence rests on nothing anyone declared and nothing any spec pins:
      # {Shell::Parse} is a STATELESS frozen object (`def initialize = freeze`,
      # no ivars), which is the shape that becomes a value. Measured with a
      # `Data.define(:parse, :capability_set)` stand-in: two verdicts over two
      # fresh Parses are not `eq`, two over a SHARED Parse are. So the guard
      # fails open the moment either half turns value-like. Do not simplify it.
      it "gives the triage rung and the bash tool the same instance, not two equal ones" do
        in_tree(config: %([shell]\nexclude = ["curl"]\n)) do |root|
          board = board_for(root:)

          expect(verdict_of_rung(board)).to equal(verdict_of_tool(board))
        end
      end

      # And the shared instance is the PROJECT's, not a shared permissive
      # default -- without this, the example above would still pass over two
      # branches that agreed on restricting nothing.
      it "carries the project's own exclusion table to both of them" do
        in_tree(config: %([shell]\nexclude = ["curl"]\n)) do |root|
          board = board_for(root:)

          expect(verdict_of_rung(board).call("curl http://example.com")).to be_deny
          expect(verdict_of_tool(board).call("curl http://example.com")).to be_deny
        end
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
            .to eq([Lain::Middleware::ConfineToScope, Lain::Middleware::RefuseSecretWrites,
                    Lain::Middleware::RedactSecretReads,
                    Lain::Middleware::WithholdSecretPaths, Lain::Middleware::GuardTestLayout,
                    Lain::Middleware::WithholdAutomaticOutput, Lain::Middleware::Sensitivity,
                    Lain::Middleware::Gate])
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

  # The fold's acceptance criteria. Six single-caller collaborators came back
  # into this class, so what used to be asserted against a module function is
  # asserted here against the object that does the work: the run's state, the
  # epic it is seated in, and -- already pinned above, at the shell verdict --
  # the ONE object two seams share.
  describe "the collaborators this class absorbed" do
    # The resumed halves arrive from the resume result rather than being
    # built fresh, and BOTH are decorated by the chronicle: decorating one and
    # not the other is a run whose usage records name a memory root its reads
    # never wrote.
    describe "a resumed run's state" do
      def recorded(item)
        Lain::Memory::Recorder.new(index: Lain::Memory::Index.empty.write(item))
      end

      let(:remembered) do
        Lain::Memory::Item.new(id: "db-conventions", description: "how this project names tables", body: "snake")
      end

      # The recorded VIEW is restored, re-opened on the project's store: the
      # same items, so the manifest is what was recorded, and a write from here
      # lands durably where the next fresh chat will see it.
      it "restores the resumed view's items rather than opening on the store head" do
        restored, = wiring.run_state(WiringSpecResumed.new(recorder: recorded(remembered),
                                                           session: Lain::Session.new))

        expect(restored.index.to_h.keys).to eq(["db-conventions"])
        expect(restored.loaded.items.map(&:id)).to eq(["db-conventions"])
      end

      # The resumed Session already holds the read-set, pin-set and todo list
      # replay restored, so it is POINTED at the re-opened view rather than
      # rebuilt -- and its manifest has to follow, or it renders a snapshot the
      # memory tools no longer write into.
      it "points the resumed session's manifest at the re-opened view" do
        session = Lain::Session.new(memory: recorded(remembered))

        restored, restored_session = wiring.run_state(WiringSpecResumed.new(recorder: recorded(remembered),
                                                                            session:))
        restored.write(Lain::Memory::Item.new(id: "later", description: "written after the resume", body: "x"))

        expect(restored_session).to be(session)
        expect(restored_session.reminders.join).to include("later")
      end

      # A resume keeps its own view on purpose, so what other chats added since
      # is reported rather than silently absent. Its own state home, because the
      # store is a FILE and the suite's is shared by every example in the process.
      it "says how many newer entries the store holds, and says nothing when it holds none" do
        Dir.mktmpdir do |state|
          isolated = described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                                         paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => state,
                                                                       "HOME" => state }))
          resumed = WiringSpecResumed.new(recorder: recorded(remembered), session: Lain::Session.new)
          restored, = isolated.run_state(resumed)

          expect(isolated.memory_notices(restored, resumed)).to eq([])
          Lain::Memory::ProjectStore.new(
            project_dir: Lain::ProjectDir.new(root: isolated.project.root,
                                              paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => state,
                                                                            "HOME" => state }))
          ).view.write(Lain::Memory::Item.new(id: "elsewhere", description: "d", body: "b"))
          expect(isolated.memory_notices(restored, resumed).join).to include("1 entry newer")
        end
      end

      it "tells a fresh chat nothing, because its view already holds them" do
        recorder, = wiring.run_state(nil)

        expect(wiring.memory_notices(recorder, nil)).to eq([])
      end

      # The fresh half, and the one thing about it that is this class's own
      # answer rather than a constructor default: a fresh Session runs at the
      # PROJECT's cwd, never at whatever `Dir.pwd` the process happens to hold.
      it "builds a fresh pair, seated at the project's own cwd" do
        recorder, session = wiring.run_state(nil)

        expect(recorder).to be_a(Lain::Memory::Recorder)
        expect(session.worker_env.cwd).to eq(wiring.chat_env.cwd)
      end
    end

    # The mount is resolved ONCE and read twice -- the toolset takes its
    # tools, an attached editor's lain://status takes its slug -- because
    # {CLI::EpicMount} builds the one {Epic::Review} per slug and a second
    # mount would be a second guard over one journal.
    describe "the epic a chat is seated in" do
      around do |example|
        Dir.mktmpdir("lain-wiring-epic") do |dir|
          @tmp = File.realpath(dir)
          FileUtils.mkdir_p(epic_root)
          with_env("XDG_STATE_HOME" => File.join(@tmp, "state")) { example.run }
        end
      end

      def epic_root = File.join(@tmp, "project")

      def seated(options = {})
        described_class.new(options: { grace: 5, **options }, chronicle:, status_feed:,
                            tty_factory: lambda { |channel:, **|
                              Lain::Frontend::TTY.new(channel:, output: StringIO.new,
                                                      history_path: File.join(@tmp, "history"))
                            }, stdin: StringIO.new("quit\n"),
                            project: Lain::Project.new(root: epic_root, cwd: epic_root, kind: :project,
                                                       detected_by: :flag))
      end

      # What the editor is HANDED, taken off the `#run` path rather than from a
      # reader: {Wiring#editor_seams} is the one place a mount becomes a view,
      # and the Repl is where that view lands. The Repl's own `#run` is stubbed
      # because the conversation is not the claim -- what the example reads is
      # the seam hash a real assembly composed on its way to one.
      def epic_handed_to_editor(chat)
        seen = {}
        allow(Lain::CLI::Repl).to receive(:new).and_wrap_original do |original, **kwargs|
          original.call(**kwargs).tap { |repl| allow(repl).to receive(:run) { |**seams| seen.replace(seams) } }
        end
        chat.run(backend:, resumed: nil, nvim: nil)
        chat.conductor.close(reason: :exit)
        seen.fetch(:epic)
      end

      def write_demo
        graph = Lain::Epic::Graph.new(issues: [Lain::Epic::Issue.new(id: "a", title: "the a issue")])
        config = Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg))
        Lain::Epic::Home.resolve(config:, paths: Lain::Paths.new, root: epic_root, slug: "demo").write_epic(graph)
      end

      it "mounts the declared epic once, so the toolset and the editor read the same mount" do
        write_demo
        chat = seated

        expect(chat.send(:epic_mount)).to be_a(Lain::CLI::EpicMount).and(equal(chat.send(:epic_mount)))
        expect(chat.send(:epic_mount).slug).to eq("demo")
      end

      it "tells the notice why a mount was abandoned, on the first call only" do
        heard = []
        chat = seated(epic: "nope")

        2.times { chat.send(:epic_mount, ->(message) { heard << message }) }

        expect(heard.size).to eq(1)
        expect(heard.first).to include("request_review is not wired")
      end

      it "hands the editor the mounted epic, folded from the root the mount resolved" do
        write_demo

        expect(epic_handed_to_editor(seated).lines)
          .to include("# epic `demo`", a_string_including("`a` the a issue"))
      end

      it "hands the editor the unmounted null when the chat is in no epic" do
        expect(epic_handed_to_editor(seated)).to equal(Lain::Frontend::Neovim::StatusView::Unmounted)
      end
    end
  end
end

# What the Agent is built FROM, driven at the seam that takes the board as an
# argument rather than resolving one: the provider the run talks to, the
# compaction wiring hung off it, the instrumentation stack, and the executor
# the board's gate closes over.
RSpec.describe Lain::CLI::Wiring, "the Agent build" do
  let(:mock_provider) do
    Lain::Provider::Mock.new(responses: [
                               Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                  stop_reason: :end_turn)
                             ])
  end
  let(:backend) { WiringAgentSpecBackend.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: mock_provider) }
  let(:chronicle) { WiringAgentSpecChronicle.new }
  let(:channel) { Lain::Channel.new }
  let(:board) { WiringAgentSpecBoard.new(Lain::Toolset.new) }
  let(:status_feed) { instance_double(Lain::StatusFeed, bind_store: nil) }
  let(:wiring) do
    described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                        project: Lain::Project.new(root: @root, cwd: @root, kind: :project, detected_by: :flag))
  end

  # The root every snapshot is rooted at reaches the build off the wiring's own
  # {Lain::Project} rather than as a keyword, which is what the snapshot example
  # below reads back. A REAL directory, because {Lain::Project} resolves its
  # root through `File.realpath` and refuses one that is not there.
  around do |example|
    Dir.mktmpdir("lain-agent-build-root") { |dir| @root = File.realpath(dir) and example.run }
  end

  def build(**overrides)
    wiring.send(:agent_over, board:, channel:, backend:, session: Lain::Session.new, **overrides)
  end

  # Both branches of the `channel:` default are reached through #wire_agent,
  # the public seam, because a run makes exactly these two provider calls and
  # in this order: the toolset build takes the Null default, and the agent
  # build takes the run's live Channel. Asking the private method directly
  # would prove the method's own arithmetic and say nothing about which caller
  # gets which, which is the whole of what this group is about.
  describe "the provider the run talks to" do
    # The SPOOLED calls a real assembly made, in the order it made them. A run
    # asks the backend for a provider on other errands too -- the library's, and
    # the summarizer arm's -- and those are not round trips this class tees, so
    # the set is the calls that named a spool at all. Its SIZE is asserted
    # because `all` over an empty list is a pass, which is exactly what a
    # regression that stopped spooling would produce.
    def spooled_calls
      recorder, session = wiring.run_state(nil)
      wiring.wire_agent(channel:, recorder:, session:, backend:)
      backend.provider_calls.select { |call| call.key?(:spool) }
    end

    it "tees every round trip into the chronicle's response spool" do
      calls = spooled_calls

      expect(calls.size).to eq(2)
      expect(calls).to all(include(spool: chronicle.spool))
    end

    # A subagent leaves the default: its stream is not rendered, so only the
    # spool tee matters there. Handing it the main chat's live Channel instead
    # would put a child's tokens on the human's screen.
    it "defaults the channel to the Null one, so an unrendered stream stays unrendered" do
      expect(spooled_calls.first[:channel]).to be(Lain::Channel::Null.instance)
    end

    it "passes the run's live channel through when one is handed in" do
      expect(spooled_calls.last[:channel]).to be(channel)
    end
  end

  # The written/not-written pair is driven through the ASSEMBLY rather than at
  # the method, over a provider that really lacks a capability the Context
  # really requires: what a flag would change is the policy, but what shipped
  # broken for twelve POC journals was the wiring -- a policy with a record
  # type, an emitter, a reader and no caller. Reaching the method directly
  # could not have caught that. The journal read back is the CHRONICLE's own
  # record journal, which is the file a live chat writes these to.
  describe "the capability degradations a run records" do
    let(:io) { StringIO.new }
    let(:chronicle) { WiringAgentSpecChronicle.new(Lain::Journal.new(io:)) }
    let(:context) { Lain::Context.new(model: "qwen3:4b", max_tokens: 64) }

    def degraded_lines
      io.string.each_line.filter_map { |line| Lain::Journal.parse(line) }
                         .select { |record| record["type"] == "capability_degraded" }
    end

    # The real ollama declaration -- `%i[streaming thinking structured_output]`,
    # no `:prompt_caching` -- against what the real default Context requires. A
    # double answering `supports?` would be asserting on the double.
    def wire_over(capabilities)
      lacking = Lain::Provider::Mock.new(capabilities:)
      recorder, session = wiring.run_state(nil)
      wiring.wire_agent(channel:, recorder:, session:,
                        backend: WiringAgentSpecBackend.new({ provider: "ollama", model: nil, max_tokens: 64 },
                                                            mock: lacking))
    end

    it "writes one record per capability the provider cannot give the context" do
      wire_over(context.requires - %i[prompt_caching])

      expect(context.requires).to include(:prompt_caching)
      expect(degraded_lines.map { |record| record.values_at("capability", "requirer", "provider") })
        .to eq([%w[prompt_caching Lain::Context Lain::Provider::Mock]])
    end

    it "writes nothing when the provider supports everything the context requires" do
      wire_over(context.requires)

      expect(io.string).to be_empty
    end

    # The wired policy is `:degrade` and may never be `:strict`:
    # `Policy::Strict#handle_missing` reuses {Lain::Provider#require!}, so the
    # missing capability above would raise {Lain::Provider::Unsupported} at turn
    # one of every ollama chat. Stated as behaviour rather than as a constant
    # comparison, so it survives the constant being renamed.
    # The one of the three that stays at the method, because it is about the
    # POLICY and not about the wiring: `:strict` would raise HERE, inside the
    # call the two examples above reach through an assembly that would then
    # never return. `journal:` is what makes driving it directly cheap -- the
    # method needs one message, so a StringIO-backed {Lain::Journal} is the
    # whole fixture.
    it "degrades rather than raising, which is the whole of why :strict is not wired" do
      lacking = Lain::Provider::Mock.new(capabilities: context.requires - %i[prompt_caching])

      expect { wiring.send(:journal_degradation, context, lacking, journal: Lain::Journal.new(io:)) }
        .not_to raise_error
      expect(described_class::DEGRADE).to eq(:degrade)
    end
  end

  describe "the provider and instrumentation the Agent is backed by" do
    subject(:backing) { wiring.send(:backing, backend, channel, -> {}, board:) }

    it "hands back the provider it spooled and the instrumentation over it" do
      expect(backing[:provider]).to be(mock_provider)
      expect(backing[:instrumentation]).to be_a(Lain::Agent::Instrumentation)
    end

    # The same class list `spec/lain/cli_spec.rb` pins through the Wiring seam,
    # asserted here against the module that now builds it: a credential-shaped
    # memory_write is withheld in the TOOL phase, before it reaches the recorder,
    # an unreleased region is masked out of a read in the same phase, before its
    # bytes can reach an Event or the prompt-cache prefix, and a sensitive path
    # is dropped out of a listing before the enumeration is believed.
    # ...and then the board's two gating layers, innermost, so a secret write
    # is refused before a human is ever asked about it.
    it "puts all three secret guards, then the test layout guard, then the board's gate, in the tool phase" do
      expect(backing[:instrumentation].tool_middleware.to_a.map(&:class))
        .to eq([Lain::Middleware::ConfineToScope, Lain::Middleware::RefuseSecretWrites,
                Lain::Middleware::RedactSecretReads,
                Lain::Middleware::WithholdSecretPaths, Lain::Middleware::GuardTestLayout,
                Lain::Middleware::WithholdAutomaticOutput, Lain::Middleware::Sensitivity, Lain::Middleware::Gate])
    end

    # An unattended run leaves {Lain::CLI::Switchboard#approvals} nil, and the
    # read guard takes its queue as a required keyword -- so the stand-in has to
    # be substituted HERE, at the wiring, or the run raises on construction.
    # Selected by CLASS, not by position: this example is about the read guard
    # being constructible without a queue, and indexing at the end of the stack
    # tied it to being the last entry, which a third guard then made false.
    it "substitutes the unqueued stand-in when the board wired no approval queue" do
      expect { backing }.not_to raise_error
      expect(backing[:instrumentation].tool_middleware.to_a.grep(Lain::Middleware::RedactSecretReads))
        .not_to be_empty
    end

    # The run's own member sits ahead of the chronicle's, so the Null
    # chronicle's empty phase is no longer an empty stack -- it is the window
    # refresh alone.
    it "takes the turn phase from the chronicle, ahead of which it puts the window refresh" do
      expect(backing[:instrumentation].turn_middleware.to_a.map(&:class))
        .to eq([Lain::Middleware::ResolveWindow])
    end

    # The OWNER of the re-resolution trigger, named here because the book
    # cannot own it: {CLI::Backend::WindowBook::Live} has no clock and no turn
    # count, and re-resolving per READ would let one turn's three readers see
    # three windows. It must refresh the run's ONE book -- the same instance
    # handed to the Agent as `context_window:` -- or the reader that self-
    # corrects is not the reader anything divides by.
    # The ordering, against a turn stack that HAS another member -- the only
    # arrangement in which the wrong order is distinguishable. Both halves are
    # asserted: what the stack holds, and what ran first.
    it "puts the window refresh outermost, ahead of the chronicle's own members" do
      trail = backend.context_window.trail
      journalling = described_class.new(
        options: { grace: 5 }, chronicle: WiringAgentSpecJournallingChronicle.new(trail), status_feed:,
        project: Lain::Project.new(root: @root, cwd: @root, kind: :project, detected_by: :flag)
      )
      stack = journalling.send(:backing, backend, channel, -> {}, board:)[:instrumentation].turn_middleware

      stack.call({}) { |env| env }

      expect(stack.to_a.map(&:class))
        .to eq([Lain::Middleware::ResolveWindow, WiringAgentSpecJournallingChronicle::Member])
      expect(trail).to eq(%i[window chronicle])
    end

    it "refreshes the very book the Agent is handed, once per turn" do
      backing[:instrumentation].turn_middleware.call({}) { |env| env }

      expect(backing[:context_window]).to be(backend.context_window)
      expect(backend.context_window.refreshes).to eq(1)
    end

    it "builds its provider over the live channel, not the Null default" do
      backing

      expect(backend.provider_calls.first[:channel]).to be(channel)
    end
  end

  describe "the Agent itself" do
    # The seam's constraint, stated as an assertion: the board ARRIVES. Were
    # this method to memoize one of its own, `Wiring#approvals`, the command
    # surface and every subagent's gate policy would each read a different
    # switchboard -- or nil.
    # `backend.context` answers a FRESH value at every call by design, so what
    # is asserted is the routing, not an identity the subject never promised:
    # the board grafted exactly once, and the Agent holds what that graft
    # returned.
    it "builds over the board it was handed, never one it resolved itself" do
      agent = build

      expect(agent.toolset).to be(board.toolset)
      expect(board.grafted.one?).to be(true)
      expect(agent.context).to be(board.grafted.first)
    end

    # The stack's order is inspectable end to end: the four guards, the path
    # refusal, the approval gate, and the interpreter last -- a bare Live,
    # because everything that may refuse a call is a layer in front of it.
    it "runs the guards, then the gate over the board's own policy, then a bare Live interpreter" do
      runner = build.send(:tool_runner)

      expect([*runner.middleware.to_a.map(&:class), runner.handler.class])
        .to eq([Lain::Middleware::ConfineToScope, Lain::Middleware::RefuseSecretWrites,
                Lain::Middleware::RedactSecretReads,
                Lain::Middleware::WithholdSecretPaths, Lain::Middleware::GuardTestLayout,
                Lain::Middleware::WithholdAutomaticOutput, Lain::Middleware::Sensitivity, Lain::Middleware::Gate,
                Lain::Effect::Handler::Live])
      expect(runner.middleware.to_a.last.instance_variable_get(:@policy)).to be(board.policy_switch)
    end

    it "seeds the Agent with a resumed Timeline when one is passed" do
      resumed = Lain::Timeline.new(head_digest: nil, store: Lain::Store.new)

      expect(build(timeline: resumed).timeline).to eq(resumed)
    end

    it "gives the Agent a RequestOverride, so the resend bridge has its slot" do
      expect(build.request_override).to be_a(Lain::Agent::RequestOverride)
    end

    # The nil-capture guard. The handle is built BEFORE the Agent it reads, so
    # it can only be a thunk over a binding assigned afterwards; a plain return
    # value would leave it nil forever and every turn-middleware read would
    # raise NoMethodError on the first turn.
    it "hands the chronicle a timeline handle that resolves to the built Agent" do
      agent = build

      expect(chronicle.timeline_handle.call).to be(agent.timeline)
    end

    # A flip into plan scope confines the session the Agent runs its tools in,
    # so the board must hold that one and no other.
    it "binds the board to the session the Agent is built over" do
      agent = build

      expect(board.session).to be(agent.session)
    end

    # The slot is born here and handed to the board, which hands it to `/undo`.
    it "hands the board a snapshot slot rooted at the project, under the board's scope" do
      build

      expect(board.snapshots).to be_a(Lain::Agent::SnapshotSlot)
      expect(board.snapshots.root).to eq(@root)
      expect(board.snapshots.label).to eq("write_set")
    end
  end

  # The shadow scope every mode writes under, from the first turn, in a chat
  # Wiring built from a project SUBDIRECTORY, with a real bash call writing a
  # file no lain tool records. Bash is tier 3 and would park on the approval
  # queue, so the board is flipped to auto first, which leaves the slot alone.
  describe "a chat Wiring launched from a subdirectory", :seam do
    around do |example|
      Dir.mktmpdir("lain-agent-build-project") do |project|
        Dir.mktmpdir("lain-agent-build-state") do |state|
          @project = File.realpath(project)
          @state = state
          FileUtils.mkdir_p(File.join(@project, "sub"))
          example.run
        end
      end
    end

    let(:shell_write) { "printf unrecorded > #{File.join(@project, "made-by-bash.txt")}" }
    let(:provider) do
      Lain::Provider::Mock.new(responses: [
                                 tool_response(["tu_1", "bash", { "command" => shell_write }]),
                                 Lain::Response.new(content: [{ "type" => "text", "text" => "done" }],
                                                    stop_reason: :end_turn)
                               ])
    end

    def wired_chat
      wiring = described_class.new(
        options: { grace: 5 }, chronicle:, status_feed: instance_double(Lain::StatusFeed),
        project: Lain::Project.new(root: @project, cwd: File.join(@project, "sub"), kind: :project,
                                   detected_by: :flag),
        paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state })
      )
      recorder, session = wiring.run_state(nil)
      [wiring, wiring.wire_agent(channel:, recorder:, session:, backend: WiringAgentSpecBackend.new(
        { provider: "ollama", model: nil, max_tokens: 64 }, mock: provider
      ))]
    end

    it "records a file no lain tool wrote in the next snapshot, rooted at the project root" do
      wiring, agent = wired_chat
      board = wiring.role_spawn.seam.tool_middleware.board.call
      board.mode_switch.switch(Lain::Mode.new(approval: :auto), surface: "spec")

      agent.ask("make it")

      entry = board.snapshots.log.to_a.last
      body = agent.timeline.store.fetch(entry.snapshot).body
      expect(entry.files.keys).to eq(["made-by-bash.txt"])
      expect(body.fetch("root")).to eq(@project)
      expect(body.fetch("snapshot_scope")).to eq(Lain::Workspace::Snapshot::Scope::ShadowGit::NOTE)
    end
  end

  describe "the switchboard memo Wiring keeps" do
    let(:status_feed) { instance_double(Lain::StatusFeed) }
    let(:wiring) { described_class.new(options: { grace: 5 }, chronicle:, status_feed:) }
    let(:wired_backend) do
      Class.new(Lain::CLI::Backend) do
        def initialize(options, mock:, root: Dir.pwd)
          super(options, root:)
          @mock = mock
        end

        def provider(**) = @mock
      end.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: mock_provider)
    end

    def wire
      recorder, session = wiring.run_state(nil)
      wiring.wire_agent(channel:, recorder:, session:, backend: wired_backend)
    end

    # Assigned as a SIDE EFFECT of building the agent: #switchboard is memoized
    # at its one call site, and three readers depend on that having happened.
    # Moving the memo into this module is the failure the card is written to
    # avoid, so the readers are what pin it.
    it "is assigned by the time the parked-approval queue is read" do
      wire

      expect(wiring.approvals).to be_a(Lain::Approval::Queue)
    end

    # Reaching {Command::Env}'s own refusal AT ALL is the assertion:
    # `@switchboard.surface_kwargs` runs first and would raise NoMethodError on
    # nil before any Env existed. What the refusal then names is the pair
    # #build_repl owns and this call deliberately withholds -- never
    # `approvals`, which is nil exactly when the memo is.
    it "is assigned by the time the command surface is assembled" do
      wire

      expect { wiring.send(:assemble_surface, agent: nil, library: nil, window: nil) }
        .to raise_error(ArgumentError, /\[:replies, :agent\]/)
    end

    # A subagent's tool stack is built by {CLI::ToolGuard::Spawned} over the
    # thunk `-> { @switchboard }`, read at SPAWN time -- turns after the Agent
    # was built, which is what lets it be late. Reached here through public
    # readers only ({Wiring#role_spawn}, {Skill::RoleSpawn#seam},
    # {Tools::Subagent::Seam#tool_middleware}), because the point is the seam a
    # child really travels over and not an ivar.
    def child_guard = wiring.role_spawn.seam.tool_middleware

    def child_gate = child_guard.call(Lain::WorkerEnv.default).to_a.last

    # Driving `.board.call` IS driving the thunk: that is the call the builder
    # makes as each child is built.
    it "is what a subagent's tool stack thunk resolves" do
      wire

      expect(child_guard.board.call).to be_a(Lain::CLI::Switchboard)
    end

    # The privilege-inversion guard, stated as the thing a child's dispatch
    # actually consults: the gate a child is built behind asks the board's
    # ONE policy switch, and calls whatever that slot currently holds.
    #
    # The queue assertion is the one that is not a tautology, and the direction
    # is the whole of why: the left side travels the CHILD's thunk out to a
    # board and back, where the right side is {Wiring}'s own reader over the
    # memo. Two paths, one object.
    #
    # What then adjudicates is the run's escalation ladder. Against an ungated
    # board it would be an unconditional approver: a child could do what its
    # parent must ask to do, which is a privilege inversion and not a wiring
    # omission.
    it "gates a child through the run's own queue, the one its parent is gated by" do
      wire
      resolved = child_guard.board.call

      expect(child_gate.instance_variable_get(:@policy).policy).to be(resolved.policy_switch)
      expect(resolved.approvals).to be(wiring.approvals)
      expect(resolved.policy_switch.current).to be_a(Lain::Approval::Escalation)
      expect(resolved.policy_switch.current).not_to be_a(Lain::Middleware::Gate::ApproveAll)
    end

    # The identity that makes the privilege inversion unrepresentable: ONE
    # board, so one {Sensitivity::Policy}, so the paths a child's gate refuses
    # are the paths its parent's gate refuses -- by construction rather than by
    # two wirings agreeing. A second thunk here would satisfy every behavioural
    # check in this suite and still point at a different session.
    #
    # `#sensitivity` is read off the resolved board rather than off Wiring,
    # which keeps no public reader for it: the board IS the parent gate's
    # source, so reading its slot is reading what the parent consults.
    it "resolves a child's sensitivity from the same board its gate policy resolves" do
      wire

      expect(child_gate.instance_variable_get(:@sensitivity)).to be(child_guard.board.call.sensitivity)
    end

    # The late half, which the two above cannot see: the thunk closes over an
    # IVAR, so it must answer the board that is there WHEN IT IS CALLED, not
    # one captured while the toolset was being built -- at which point the memo
    # is still nil. Building the toolset alone and reading the thunk before the
    # agent exists is the only place that distinction is visible.
    it "reads nil until the agent build assigns it, which is what makes the thunk late" do
      recorder, = wiring.run_state(nil)
      wiring.send(:build_toolset, recorder, backend: wired_backend, parent: -> {},
                                            ask_human: Lain::Tools::AskHuman.new(parent: -> {}))

      expect(wiring.role_spawn.seam.tool_middleware.board.call).to be_nil
    end
  end
end

# The capability floor's own seam, and it earns a group of its own for one
# thing the assemblers above it cannot show. This module is where the session's
# {Lain::Shell::Verdict} reaches {Lain::Tools::Bash}, and the keyword carrying
# it has a permissive default -- which is exactly how an unwired guard ships
# green forever. So what is asserted here is the IDENTITY of what arrives,
# alongside the default staying indistinguishable from the tool's own.
RSpec.describe Lain::CLI::Wiring::BaseTools do
  let(:recorder) { Lain::Memory::Recorder.new }
  let(:channel) { RecordingChannel.new }

  # `@verdict` is read through the ivar for `toolset_build_spec`'s reason:
  # {Lain::Tools::Bash} exposes no reader, and adding one to widen a spec's
  # reach would be the spec shaping the subject.
  def bash_in(floor) = floor.find { |tool| tool.name == "bash" }

  def verdict_of(floor) = bash_in(floor).instance_variable_get(:@verdict)

  def excluding(*programs)
    Lain::Shell::Verdict.new(capability_set: Lain::Shell::Exclusions.new(patterns: programs))
  end

  # The keyword carrying the session's journal has a Null default too, and a
  # permissive default is exactly how a wired-looking guard ships doing nothing.
  # So this is driven through {Lain::CLI::Wiring::ToolsetBuild} -- the object
  # that assembles this floor for every chat -- with the real bash tool running
  # a real command and NO double anywhere below the assembler. What is asserted
  # is that the record lands in the journal that session was built with.
  describe "the journal a live session's assembler hands the floor" do
    let(:backend) { Lain::CLI::Backend.new({ provider: "ollama", model: nil, max_tokens: 64 }, root: Dir.pwd) }
    let(:chronicle) { Lain::CLI::Chronicle::Null.new }
    let(:journal) { RecordingChannel.new }
    let(:parent) { -> { Lain::Timeline.new } }
    let(:assembler) do
      Lain::CLI::Wiring::ToolsetBuild.new(backend:, provider: backend.provider(spool: chronicle.spool),
                                          chronicle:, options: {}, supervisor: Lain::Supervisor.new(journal:),
                                          parent:, journal:, library: backend.library,
                                          epic: Lain::CLI::EpicMount::NoEpic, root: Dir.pwd,
                                          switchboard: -> { SpecNulls::NoSwitchboard },
                                          askers: SpecNulls::UnwiredAskers.build)
    end

    def live_bash = assembler.build(recorder, ask_human: Lain::Tools::AskHuman.new(parent:)).fetch("bash")

    it "lands the bash tool's arm record in that session's journal" do
      live_bash.call({ command: "ls -la" }, Lain::Tool::Invocation.new(tool_use_id: "tu_live", channel:))

      expect(journal.events.grep(Lain::Telemetry::ShellArm).map { |arm| [arm.tool_use_id, arm.verdict] })
        .to eq([["tu_live", :allow]])
    end
  end

  describe "the floor itself" do
    it "hands the bash tool the verdict it was built with, by identity" do
      chosen = excluding("curl")

      expect(verdict_of(described_class.build(recorder, verdict: chosen))).to be(chosen)
    end

    # The behavioural half of the same claim: the floor's bash really answers
    # through the session's table, so a program the project ruled out is a
    # refusal at the tool's own arm choice too.
    it "gives the floor a verdict that refuses the program the session excluded" do
      floor = described_class.build(recorder, verdict: excluding("curl"))

      expect(verdict_of(floor).call("curl http://example.com")).to be_deny
    end

    # The exec tools are named in one place production reads
    # ({Lain::Approval::Escalation::Triage::COMMAND_TOOLS}) and built in one
    # place a chat reaches (this floor). A name on that list the floor never
    # builds is a tool nothing can reach while the approval vocabulary still
    # vouches for it -- which is how a second exec tool sat there unoffered.
    # So the two halves are asserted against each other rather than separately.
    it "offers bash, and names no command tool the floor does not build" do
      names = described_class.build(recorder).map(&:name)

      expect(names).to include("bash")
      expect(Lain::Approval::Escalation::Triage::COMMAND_TOOLS - names).to be_empty
    end

    # The floor is what a subagent role attenuates FROM, so the ONE bash the
    # floor holds is the one a child inherits -- there is no second tool to
    # wire, and no way for a child's verdict to differ from its parent's.
    it "builds exactly one bash, so a child cannot inherit a different verdict" do
      floor = described_class.build(recorder, verdict: excluding("curl"))

      expect(floor.count { |tool| tool.name == "bash" }).to eq(1)
    end

    # The default is what an unwired build gets, and it must restrict nothing:
    # a floor built with no session behaves byte-for-byte as it did before the
    # keyword existed.
    it "defaults to a verdict that restricts no program" do
      expect(verdict_of(described_class.build(recorder)).call("curl http://example.com")).to be_allow
    end

    # A bash built with no verdict at all still runs the term arm, which is the
    # property the default exists to protect: `Tools::Subagent` runs an ungated
    # handler and `bash_spec` constructs the tool alone, so sharing the
    # session's instance has to stay an INJECTION rather than a dependency.
    it "still runs the term arm with no verdict wired, and spawns no shell" do
      seen = []
      real = Lain::Shell::Pipeline.new
      pipeline = lambda do |term, **options|
        seen << term
        real.call(term, **options)
      end
      floor = described_class.build(recorder, exec: Lain::Exec::Local.new(pipeline:))

      result = bash_in(floor).call({ command: "ls -la" }, Lain::Tool::Invocation.new(tool_use_id: "tu_1", channel:))

      expect(seen).to eq([[%w[ls -la]]])
      expect(result).to be_ok
      expect(result.content).to include("exit status: 0")
    end

    # {Lain::Tool::FileTarget} is a MIXIN, so nothing constructs it and no spec
    # of its own can prove the floor's tools really carry it. This drives the
    # read_file the floor built -- no double anywhere below the assembler --
    # against a session whose cwd is not the process's, which is the one
    # observable difference between resolving through the seam and resolving
    # against Dir.pwd the way these tools each used to.
    it "gives the floor's file tools the session's cwd to resolve against" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "inside the session cwd\n")
        session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env: ENV.to_h))
        read_file = described_class.build(recorder).find { |tool| tool.name == "read_file" }

        result = read_file.call({ path: "a.txt" },
                                Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session))

        expect(result).to be_ok
        expect(result.content).to include("inside the session cwd")
      end
    end
  end
end

# How the chat handoff finds the repository a worker's work merges back into.
# It used to derive that separately from the {Lain::Isolation::Worktree}
# backend that actually cut the worker checkouts -- a second, git-shelled
# `rev-parse --show-toplevel` that can disagree with the backend's own answer
# under GIT_CEILING_DIRECTORIES (see the divergence example below). Reading
# the backend's own #repo_root instead makes the two answers unrepresentable
# as different directories.
RSpec.describe Lain::CLI::Wiring, "the handback a worker's work comes home on", :seam do
  around do |example|
    Dir.mktmpdir("lain-handback-repo") do |dir|
      @repo = File.realpath(dir)
      init_repo(@repo)
      @root = File.join(@repo, "sub")
      FileUtils.mkdir_p(@root)
      example.run
    end
  end

  def init_repo(dir) = FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", dir)

  # The fleet backend a `--isolation worktree` chat resolves, reached through
  # the wiring rather than built beside it: what is under test is the handback
  # the run's OWN isolation produces, and a second backend built here could
  # answer a different repository than the one the run cut checkouts from.
  def handback_of_chat
    described_class.new(options: { grace: 5, isolation: "worktree" },
                        chronicle: Lain::CLI::Chronicle::Null.new,
                        status_feed: instance_double(Lain::StatusFeed),
                        project: Lain::Project.new(root: @root, cwd: @root, kind: :project, detected_by: :flag))
                   .send(:handback, nil)
  end

  it "wires the handoff with the working branch's repository" do
    expect(handback_of_chat.handoff).not_to equal(Lain::Isolation::WorkerHandoff::Null)
  end

  # THE DIVERGENCE. `--isolation worktree` launched from a SUBDIRECTORY of the
  # repository, under GIT_CEILING_DIRECTORIES pointed at the repository root
  # itself: git's own discovery walk stops BEFORE reaching that root when it
  # starts below it (verified against a real `git rev-parse --show-toplevel`),
  # so a handoff that re-derives its root by shelling out raises where the
  # backend -- whose own repository search is a plain directory walk, not a
  # git subprocess -- resolved and cut worktrees just fine.
  it "answers from the backend's own repository rather than raising under GIT_CEILING_DIRECTORIES" do
    with_env("GIT_CEILING_DIRECTORIES" => @repo) do
      handback = nil
      expect { handback = handback_of_chat }.not_to raise_error

      expect(handback.handoff.instance_variable_get(:@repo_root)).to eq(@repo)
    end
  end
end
