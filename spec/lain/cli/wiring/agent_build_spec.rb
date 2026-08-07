# frozen_string_literal: true

# Records what the backend was asked for a provider WITH, because
# {Lain::CLI::Wiring::AgentBuild.spooled_provider}'s whole content is the pair
# of keywords it passes -- the spool tee and the channel -- and the object that
# comes back is the same mock either way. Only the network edge is faked; the
# rest is the real {Lain::CLI::Backend} the exe builds.
class AgentBuildSpecBackend < Lain::CLI::Backend
  attr_reader :provider_calls

  def initialize(options, mock:)
    super(options)
    @mock = mock
    @provider_calls = []
  end

  def provider(**kwargs)
    @provider_calls << kwargs
    @mock
  end
end

# Captures the timeline handle {AgentBuild} hands the chronicle so an example
# can call it back AFTER the Agent exists. That is the only way to see whether
# the closure caught a live binding or a permanent nil -- the defect
# `wiring.rb` documents at its own `agent = build_agent(...)` line, and the one
# this extraction could most easily reintroduce by returning where it used to
# assign.
class AgentBuildSpecChronicle < Lain::CLI::Chronicle::Null
  attr_reader :timeline_handle

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

# The Switchboard's side of the seam, recorded. A stand-in rather than the real
# board because the point of the extraction is that {AgentBuild} is HANDED one:
# what an example needs to see is which object the Agent was built over, and
# that the module never went looking for a board of its own.
class AgentBuildSpecBoard
  attr_reader :toolset, :gate_calls, :grafted

  def initialize(toolset)
    @toolset = toolset
    @gate_calls = []
    @grafted = []
  end

  def gate(inner:)
    @gate_calls << inner
    Lain::Effect::Handler::Gate.new(policy: Lain::Tools::Subagent::UNGATED, inner:)
  end

  def graft(context)
    @grafted << context
    context
  end
end

RSpec.describe Lain::CLI::Wiring::AgentBuild do
  let(:mock_provider) do
    Lain::Provider::Mock.new(responses: [
                               Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                  stop_reason: :end_turn)
                             ])
  end
  let(:backend) { AgentBuildSpecBackend.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: mock_provider) }
  let(:chronicle) { AgentBuildSpecChronicle.new }
  let(:channel) { Lain::Channel.new }
  let(:board) { AgentBuildSpecBoard.new(Lain::Toolset.new) }

  def build(**overrides)
    described_class.build(board:, chronicle:, channel:, backend:, session: Lain::Session.new, **overrides)
  end

  describe ".spooled_provider" do
    it "tees every round trip into the chronicle's response spool" do
      described_class.spooled_provider(backend, chronicle:)

      expect(backend.provider_calls.first).to include(spool: chronicle.spool)
    end

    # A subagent leaves the default: its stream is not rendered, so only the
    # spool tee matters there. Handing it the main chat's live Channel instead
    # would put a child's tokens on the human's screen.
    it "defaults the channel to the Null one, so an unrendered stream stays unrendered" do
      described_class.spooled_provider(backend, chronicle:)

      expect(backend.provider_calls.first[:channel]).to be(Lain::Channel::Null.instance)
    end

    it "passes the run's live channel through when one is handed in" do
      described_class.spooled_provider(backend, chronicle:, channel:)

      expect(backend.provider_calls.first[:channel]).to be(channel)
    end
  end

  describe ".backing" do
    subject(:backing) { described_class.backing(backend, channel, -> {}, chronicle:) }

    it "hands back the provider it spooled and the instrumentation over it" do
      expect(backing[:provider]).to be(mock_provider)
      expect(backing[:instrumentation]).to be_a(Lain::Agent::Instrumentation)
    end

    # The same class list `spec/lain/cli_spec.rb` pins through the Wiring seam,
    # asserted here against the module that now builds it: a credential-shaped
    # memory_write is withheld in the TOOL phase, before it reaches the recorder.
    it "puts the secret-write guard in the tool phase" do
      expect(backing[:instrumentation].tool_middleware.to_a.map(&:class))
        .to eq([Lain::Middleware::RefuseSecretWrites])
    end

    it "takes the turn phase from the chronicle, which is empty for the Null one" do
      expect(backing[:instrumentation].turn_middleware.to_a).to eq([])
    end

    it "builds its provider over the live channel, not the Null default" do
      backing

      expect(backend.provider_calls.first[:channel]).to be(channel)
    end
  end

  describe ".build" do
    # The card's constraint, stated as an assertion: the board ARRIVES. Were
    # this module to memoize one of its own, `Wiring#approvals`, the command
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

    it "wraps a Live executor over the board's toolset in the board's own gate" do
      build

      expect(board.gate_calls.map(&:class)).to eq([Lain::Effect::Handler::Live])
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
  end

  describe "the switchboard memo Wiring keeps" do
    let(:status_feed) { instance_double(Lain::StatusFeed) }
    let(:wiring) { Lain::CLI::Wiring.new(options: { grace: 5 }, chronicle:, status_feed:) }
    let(:wired_backend) do
      Class.new(Lain::CLI::Backend) do
        def initialize(options, mock:)
          super(options)
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

      expect { wiring.send(:assemble_surface, agent: nil, library: nil, tty: nil) }
        .to raise_error(ArgumentError, /\[:replies, :agent\]/)
    end

    # A subagent's gate policy is {ToolsetBuild::LivePolicy} over the thunk
    # `-> { @switchboard }`, read at SPAWN time -- turns after the Agent was
    # built, which is what lets it be late. Reached here through public readers
    # only ({Wiring#role_spawn}, {Skill::RoleSpawn#seam},
    # {Tools::Subagent::Seam#gate_policy}), because the point is the seam a
    # child really travels over and not an ivar.
    def child_gate_policy = wiring.role_spawn.seam.gate_policy

    # Driving `.board.call` IS driving the thunk: that is the call
    # {LivePolicy#call} makes on every child tier-3 dispatch. The alternative
    # it must not resolve is named, because {ToolsetBuild}'s own default is a
    # thunk over {ToolsetBuild::NoSwitchboard} -- an ungated board that is
    # explicitly "not a sanctioned production state".
    it "is what a subagent's gate policy thunk resolves, not the ungated default" do
      wire

      expect(child_gate_policy.board.call).to be_a(Lain::CLI::Switchboard)
      expect(child_gate_policy.board.call).not_to be(Lain::CLI::Wiring::ToolsetBuild::NoSwitchboard)
    end

    # The privilege-inversion guard, stated as the thing a child's dispatch
    # actually consults: {LivePolicy#call} resolves the board, asks it for
    # `policy_switch`, and calls whatever that slot currently holds.
    #
    # The queue assertion is the one that is not a tautology, and the direction
    # is the whole of why: the left side travels the CHILD's thunk out to a
    # board and back, where the right side is {Wiring}'s own reader over the
    # memo. Two paths, one object. Comparing a board's `approvals` against
    # itself -- which an earlier edition of this example did -- is
    # `x.approvals == x.approvals` and passes for any board at all, including
    # the ungated one.
    #
    # What then adjudicates is the run's escalation ladder. Against
    # {NoSwitchboard} it is {Tools::Subagent::UNGATED}, an unconditional
    # approver: a child could do what its parent must ask to do, which is a
    # privilege inversion and not a wiring omission.
    it "gates a child through the run's own queue, the one its parent is gated by" do
      wire
      resolved = child_gate_policy.board.call

      expect(resolved.approvals).to be(wiring.approvals)
      expect(resolved.policy_switch.current).to be_a(Lain::Approval::Escalation)
      expect(resolved.policy_switch.current).not_to be_a(Lain::Effect::Handler::Gate::ApproveAll)
    end

    # T11's third axis, over the SAME seam and the SAME thunk. It matters that
    # both chains resolve one board rather than two: a `LiveSensitivity` built
    # over a second thunk would answer a different session's policy, and every
    # behavioural check would still agree while nothing was configured.
    def child_sensitivity = wiring.role_spawn.seam.sensitivity

    it "resolves a child's sensitivity through the run's own board, not the ungated default" do
      wire

      expect(child_sensitivity.board.call).to be_a(Lain::CLI::Switchboard)
      expect(child_sensitivity.board.call).not_to be(Lain::CLI::Wiring::ToolsetBuild::NoSwitchboard)
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
    it "resolves that sensitivity from the same board its gate policy resolves" do
      wire
      board = child_sensitivity.board.call

      expect(board).to be(child_gate_policy.board.call)
      expect(child_sensitivity.board.call.sensitivity).to be(board.sensitivity)
    end

    # The late half, which the two above cannot see: the thunk closes over an
    # IVAR, so it must answer the board that is there WHEN IT IS CALLED, not
    # one captured while the toolset was being built -- at which point the memo
    # is still nil. Building the toolset alone and reading the thunk before the
    # agent exists is the only place that distinction is visible.
    it "reads nil until the agent build assigns it, which is what makes the thunk late" do
      recorder, = wiring.run_state(nil)
      wiring.send(:build_toolset, recorder, backend: wired_backend, parent: -> {},
                                            journal: channel, ask_human: Lain::Tools::AskHuman.new(parent: -> {}))

      expect(wiring.role_spawn.seam.gate_policy.board.call).to be_nil
    end
  end
end
