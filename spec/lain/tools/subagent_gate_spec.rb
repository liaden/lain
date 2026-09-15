# frozen_string_literal: true

require "async"
require "stringio"

# Kept out of the RSpec block (Lint/ConstantDefinitionInBlock), the shape
# approval_spec.rb's fixtures use.
module SubagentGateSupport
  # Every role the harness spawns with NO human attached, read from the spawn
  # sites rather than spelled out here.
  #
  # Be precise about what that buys, because it is not everything: these are
  # still four hand-picked constants, so a FIFTH unattended spawner is covered
  # only if someone adds its constant too. What the indirection does buy is
  # that a spawn site which RENAMES its role -- to one holding `bash`, say --
  # cannot quietly slip past the audit, because the name arrives from the site
  # itself and the second example below pins what the four resolve to. The
  # remaining `role_spawn.call` sites were surveyed (`Consolidation::ROLE`,
  # `Improve::ROLE`, {Gherkin::TestGeneration}, {CLI::Command::Meta}) and none
  # is a new unattended tier-3 exposure.
  UNATTENDED_SPAWNS = [
    # Spawned when a worker's handback conflicts, with no human attached.
    Lain::Isolation::WorkerHandoff::ROLE,
    # The opt-in third approval surface: it judges a call ALREADY parked on
    # the queue.
    Lain::Approval::AutoSurface::ROLE,
    # The artifact gate's two halves -- the judge, and the researcher it sends
    # to gather evidence first. `EVIDENCE_ROLE` is the one a hand-written list
    # misses, because that file names it second.
    Lain::Approval::Gate::Adjudicator::ROLE,
    Lain::Approval::Gate::Adjudicator::EVIDENCE_ROLE
  ].freeze

  # A tool whose name and tier are constructor arguments, so one class covers a
  # whole role's `only`-set. The tier is what matters and the bytes are not:
  # `bash` here answers {Lain::Tool#requires_approval?} exactly as
  # {Lain::Tools::Bash} does and runs NOTHING, because a spec about a gate must
  # never be able to shell out to observe it.
  class NamedTool < Lain::Tool
    attr_reader :name, :runs

    def initialize(name, gated: false)
      super()
      @name = name.to_s
      @gated = gated
      @runs = []
    end

    def description = "the #{@name} tool"
    def requires_approval? = @gated
    def input_schema = { type: :object, properties: { text: { type: :string } }, required: [] }

    def perform(input, _invocation)
      @runs << input
      Lain::Tool::Result.ok("#{@name} ran")
    end
  end

  # A gate policy that records what it was asked and answers a fixed verdict.
  # The "no approval is requested" scenarios need it: an empty queue is
  # evidence of absence only when something WOULD have filled it.
  class SpyPolicy
    attr_reader :asked

    def initialize(verdict: true)
      @verdict = verdict
      @asked = []
    end

    def call(effect, _context)
      @asked << effect.name
      @verdict
    end
  end
end

# A child spawned by the subagent tool runs behind the SAME approval gate
# its parent does. Until this landed, `bash` was gated for the parent and
# ungated for every child holding it -- and four shipped roles hold it.
#
# The parent's gate arrives on the spawn {Seam} and nowhere else, as the tool
# guard whose last layer is the gate a tier-3 call must pass. The examples below
# build that guard with the real {CLI::ToolGuard}, so a child is gated by the
# same builder a chat's own stack comes from.
RSpec.describe "Subagent gating" do
  let(:store) { Lain::Store.new }
  let(:parent) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                  .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
  end

  # The union is exactly the `:dev` role's `only`-set, so every role under test
  # attenuates against real catalog names rather than invented ones. `bash` is
  # its one tier-3 member, and `:merge_resolver`'s four names are a subset.
  let(:tools) do
    Lain::Role::Catalog[:dev].only.to_h do |name|
      [name, SubagentGateSupport::NamedTool.new(name, gated: name == :bash)]
    end
  end
  let(:union) { Lain::Toolset.new(tools.values) }
  let(:child_context) { Lain::Context.new(model: "child-model", max_tokens: 256) }
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }
  let(:journal) { Lain::Channel::Null.instance }

  # What a spawn left behind, watched through the seam's own `observer:`.
  let(:record) { SpawnRecord.new }

  def mock(*responses) = Lain::Provider::Mock.new(responses:)

  # `gate_policy:` and `sensitivity:` are what the guard is gated BY; an
  # example that names neither gets a gate approving everything over no path
  # policy, which is what a seam nobody taught about a gate stands for.
  def seam(provider:, observer: record, gate_policy: Lain::Middleware::Gate::ApproveAll.new,
           sensitivity: Lain::Sensitivity::Policy::Null.instance, **over)
    Lain::Tools::Subagent::Seam.new(provider:, context_factory: -> { child_context }, parent:, journal:,
                                    tool_middleware: ToolRegistry.gated(policy: gate_policy, sensitivity:),
                                    observer:, **over)
  end

  def build_subagent(provider:, role: :dev, posture: :schema, **over)
    Lain::Tools::Subagent.new(
      seam: seam(provider:, **over), toolset: union,
      policy: Lain::Role::Catalog[role].spawn_policy(posture:),
      budget: Lain::Agent::Budget.new, max_depth: 1
    )
  end

  # One scripted round naming `name`, then a settling text turn.
  def calls(name, input = { "text" => "x" })
    [tool_response(["c1", name, input]), text_response("done")]
  end

  def rendered(provider) = provider.requests.first.tools.map { |tool| tool["name"] }

  def tool_results(timeline)
    timeline.to_a
            .select { |turn| turn.role == "user" }
            .flat_map(&:content)
            .select { |block| block["type"] == "tool_result" }
  end

  # ---- Scenario: a child holding bash gates exactly as the parent does -------

  describe "a child holding bash" do
    let(:journal_io) { StringIO.new }
    let(:queue) { Lain::Approval::Queue.new(journal: Lain::Journal.new(io: journal_io)) }

    it "parks its bash call on the same queue the parent's gate holds" do
      tool = build_subagent(provider: mock(*calls("bash", { "text" => "rm -rf /" })), gate_policy: queue)

      Sync do |task|
        spawn = task.async { tool.call({ "prompt" => "go" }, invocation) }
        pending = queue.dequeue

        expect(pending.tool).to eq("bash")
        expect(tools[:bash].runs).to be_empty

        pending.deny(surface: "spec")
        spawn.wait
      end

      expect(tools[:bash].runs).to be_empty
    end

    it "runs the call once the queue approves it, so the gate is a gate and not a wall" do
      tool = build_subagent(provider: mock(*calls("bash")), gate_policy: queue)

      Sync do |task|
        spawn = task.async { tool.call({ "prompt" => "go" }, invocation) }
        queue.dequeue.approve(surface: "spec")
        spawn.wait
      end

      expect(tools[:bash].runs.size).to eq(1)
    end

    it "leaves an ungated sibling call untouched, so only the tier-3 tool asks" do
      policy = SubagentGateSupport::SpyPolicy.new
      tool = build_subagent(provider: mock(*calls("read_file")), gate_policy: policy)
      tool.call({ "prompt" => "go" }, invocation)

      expect(policy.asked).to be_empty
      expect(tools[:read_file].runs.size).to eq(1)
    end
  end

  # ---- A mode never narrows what a child may hold ----------------------------

  describe "a child's rendered set" do
    it "is its role's set plus its own asker, whatever mode the parent is in" do
      provider = mock(text_response("done"))
      build_subagent(provider:).call({ "prompt" => "go" }, invocation)

      expect(rendered(provider)).to eq((union.names + %w[ask_human]).sort)
    end
  end

  # ---- Scenario: the merge_resolver role still runs unattended ---------------

  describe "an unattended role under a parent in ask" do
    it "never reaches the gate, because it holds no tier-3 tool" do
      policy = SubagentGateSupport::SpyPolicy.new(verdict: false)
      tool = build_subagent(provider: mock(*calls("edit_file")), role: :merge_resolver, gate_policy: policy)
      tool.call({ "prompt" => "go" }, invocation)

      expect(policy.asked).to be_empty
      expect(tools[:edit_file].runs.size).to eq(1)
    end

    # The deadlock the card names, asked of the REAL shipped tools rather than
    # of this file's doubles: a queue nobody is watching must not be reachable
    # from a role the harness spawns with no human attached.
    #
    # The set is DERIVED from the spawn sites, never listed here. A hand-kept
    # list is a guard that only guards what someone remembered: it passes
    # unchanged when a new unattended spawn is added, which is exactly the case
    # it exists to catch. Reading the constants makes adding an unattended
    # spawn site the thing that widens the audit -- and the constants
    # themselves are pinned below, so a rename cannot quietly shrink it either.
    it "holds no gated tool in any role the harness spawns unattended" do
      gated = SubagentGateSupport::UNATTENDED_SPAWNS.flat_map do |role|
        Lain::Role::Catalog[role].only.select { |name| ToolRegistry.build(name.to_s).requires_approval? }
      end

      expect(gated).to be_empty
    end

    # The derivation above is only as good as the constants it reads: a
    # spawn site that renames its role to one holding `bash` must fail HERE,
    # loudly, rather than silently widening what runs unattended.
    it "spawns exactly the four roles this audit covers" do
      expect(SubagentGateSupport::UNATTENDED_SPAWNS)
        .to eq(%i[merge_resolver auto_approver gate_adjudicator researcher])
    end
  end

  # ---- Scenario: a refused call is a tool error, never a raise ---------------

  describe "a denied call" do
    it "reaches the child as a tool_result marked is_error, and the spawn still returns" do
      tool = build_subagent(provider: mock(*calls("bash")), gate_policy: Lain::Middleware::Gate::DenyAll.new)
      result = tool.call({ "prompt" => "go" }, invocation)

      expect(result.is_error).to be(false)
      refusal = tool_results(record.child(store)).first
      expect(refusal["is_error"]).to be(true)
      expect(refusal["content"]).to include("approval denied")
      expect(tools[:bash].runs).to be_empty
    end
  end

  # ---- Where the gate sits in the child's chain -----------------------------

  describe "under the handler_union posture" do
    # The gate goes INSIDE the refusal, not outside it: a call the child was
    # never attenuated to is refused outright, never parked for a human who
    # would then watch it be refused anyway.
    it "refuses a disallowed tier-3 call without ever asking the policy" do
      policy = SubagentGateSupport::SpyPolicy.new
      tool = build_subagent(provider: mock(*calls("bash")), role: :merge_resolver,
                            posture: :handler_union, gate_policy: policy)
      tool.call({ "prompt" => "go" }, invocation)

      expect(policy.asked).to be_empty
      expect(tool_results(record.child(store)).first["is_error"]).to be(true)
    end

    it "still gates a call the child WAS attenuated to" do
      policy = SubagentGateSupport::SpyPolicy.new(verdict: false)
      tool = build_subagent(provider: mock(*calls("bash")), posture: :handler_union, gate_policy: policy)
      tool.call({ "prompt" => "go" }, invocation)

      expect(policy.asked).to eq(%w[bash])
      expect(tools[:bash].runs).to be_empty
    end
  end

  # ---- The stack a built child really runs behind ---------------------------
  #
  # Read off a child Agent the builder really built, because what is asserted
  # is the order of a security posture: the guards first, then a call the child
  # was never attenuated to is refused, a denied path next, and only then may a
  # human be asked -- and the interpreter, last, is a bare Live that refuses
  # nothing.
  describe "the child's tool stack" do
    let(:path_policy) do
      Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: "/home/tester",
                                                                       cwd: "/home/tester/project"))
    end

    let(:guards) do
      [Lain::Middleware::RefuseSecretWrites, Lain::Middleware::RedactSecretReads,
       Lain::Middleware::WithholdSecretPaths, Lain::Middleware::GuardTestLayout]
    end

    def child(posture: :schema, sensitivity: path_policy, role: :dev)
      Lain::Tools::Subagent::ChildBuilder.new(
        seam: seam(provider: mock, gate_policy: SubagentGateSupport::SpyPolicy.new(verdict: false), sensitivity:),
        toolset: union, policy: Lain::Role::Catalog[role].spawn_policy(posture:), budget: Lain::Agent::Budget.new
      ).build(parent, ceiling: 1).agent
    end

    def runner_of(agent) = agent.send(:tool_runner)

    def listed(agent) = [*runner_of(agent).middleware.to_a.map(&:class), runner_of(agent).handler.class]

    it "puts the path refusal outside the gate, both over the guard's one policy, and a bare Live last" do
      built = child

      expect(listed(built))
        .to eq([*guards, Lain::Middleware::Sensitivity, Lain::Middleware::Gate, Lain::Effect::Handler::Live])
      expect(runner_of(built).middleware.to_a.last(2).map { |layer| layer.instance_variable_get(:@sensitivity) })
        .to all(be(path_policy))
    end

    it "refuses a denied path through the stack a built child really holds" do
      runner = runner_of(child)
      response = tool_response(["c1", "read_file", { "path" => "/home/tester/.ssh/id_rsa" }])

      refusal = runner.run(response, context: nil).first

      expect(refusal).to include("is_error" => true)
      expect(refusal["content"]).to include("protected path")
    end

    # Between the guards and the path refusal: after the guards, so they still
    # see every call; outside the gate, so a disallowed call is never parked;
    # and the gate still the last layer before the interpreter.
    it "puts the unpermitted-call refusal just outside the path refusal under the handler_union posture" do
      expect(listed(child(posture: :handler_union, role: :merge_resolver)))
        .to eq([*guards, Lain::Middleware::RefuseUnpermitted, Lain::Middleware::Sensitivity,
                Lain::Middleware::Gate, Lain::Effect::Handler::Live])
    end

    # The gate judges what the runner resolves, and under `handler_union` the
    # runner resolves against the UNION the child renders, as the gate always
    # has; the refusal layer is what holds the child to its `only`-set.
    it "resolves a union child's calls against the union it renders" do
      built = child(posture: :handler_union, role: :merge_resolver)

      expect(runner_of(built).toolset.names).to eq(built.toolset.names)
      expect(built.toolset.names).to include("bash")
    end

    # A thunk may hand every child the one stack it holds; inserting the
    # refusal into THAT would reach every sibling and the parent it came from.
    it "inserts the unpermitted-call refusal into a copy, never into the stack the guard handed over" do
      shared = ToolRegistry::UNGUARDED.call(Lain::WorkerEnv.default)
      builder = Lain::Tools::Subagent::ChildBuilder.new(
        seam: seam(provider: mock).with(tool_middleware: ->(_worker_env) { shared }), toolset: union,
        policy: Lain::Role::Catalog[:merge_resolver].spawn_policy(posture: :handler_union),
        budget: Lain::Agent::Budget.new
      )

      builder.build(parent, ceiling: 1)

      expect(shared.to_a.map(&:class)).to eq([Lain::Middleware::Sensitivity, Lain::Middleware::Gate])
    end
  end

  # ---- A builder whose stack the gate does not close ----------------------
  #
  # The seam's builder is the one place a child's gate comes from, so a child
  # is built only over a stack the path refusal and the gate end -- refused as
  # the child is built, before any tool it holds can run.
  describe "a builder whose stack the gate does not close" do
    def spawned_over(builder, posture: :schema)
      tool = Lain::Tools::Subagent.new(
        seam: seam(provider: mock(*calls("bash"))).with(tool_middleware: builder), toolset: union,
        policy: Lain::Role::Catalog[:dev].spawn_policy(posture:), budget: Lain::Agent::Budget.new, max_depth: 1
      )
      tool.call({ "prompt" => "go" }, invocation)
    end

    def empty = ->(_worker_env) { Lain::Middleware::Stack.new }

    it "refuses a child over an empty stack, and bash never runs" do
      expect { spawned_over(empty) }.to raise_error(Lain::Middleware::Gate::Unclosed)
      expect(tools[:bash].runs).to be_empty
    end

    it "refuses it by the same name under the handler_union posture" do
      expect { spawned_over(empty, posture: :handler_union) }.to raise_error(Lain::Middleware::Gate::Unclosed)
      expect(tools[:bash].runs).to be_empty
    end

    it "refuses a child whose stack has a layer after the gate" do
      after_gate = lambda do |worker_env|
        ToolRegistry::UNGUARDED.call(worker_env).use(Lain::Middleware::RefuseSecretWrites.new)
      end

      expect { spawned_over(after_gate) }.to raise_error(Lain::Middleware::Gate::Unclosed)
      expect(tools[:bash].runs).to be_empty
    end
  end

  # ---- One builder, parent and child ---------------------------------------
  #
  # Driven over a REAL board and the real spawn wiring a chat builds
  # ({CLI::Wiring::ToolsetBuild}), because what is asserted is that the parent's
  # stack and a child's come out of the same {CLI::ToolGuard} over the same
  # board -- which a hand-built seam could satisfy while production did not.
  describe "the stack a chat and its children are gated by" do
    let(:chronicle) { Lain::CLI::Chronicle::Null.new }
    let(:path_policy) do
      Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: "/home/tester",
                                                                       cwd: "/home/tester/project"))
    end
    let(:base) { Lain::Toolset.new(ToolRegistry.names.map { |name| ToolRegistry.build(name) }) }
    let(:session_journal) { Lain::Journal.new(io: StringIO.new) }

    def board(attended: true)
      @board ||= Lain::CLI::Switchboard.new(journal: session_journal, model: "m", toolset: base,
                                            sensitivity: path_policy, attended:)
    end

    # The run's spawn wiring over `board`, built as a chat builds it, with the
    # scripted provider every child it spawns talks to.
    def wired(provider)
      backend = Lain::CLI::Backend.new({ provider: "ollama", model: nil, max_tokens: 64 })
      the_board = board
      build = Lain::CLI::Wiring::ToolsetBuild.new(
        backend:, provider:, chronicle:, options: {}, supervisor: Lain::Supervisor.new(journal:),
        parent: -> { parent }, journal:, library: backend.library, epic: Lain::CLI::EpicMount::NoEpic,
        root: "/home/tester/project", switchboard: -> { the_board }, askers: SpecNulls::UnwiredAskers.build
      )
      [build, build.build(Lain::Memory::Recorder.new, ask_human: Lain::Tools::AskHuman.new(parent: -> { parent }))]
    end

    def recording(ran)
      Lain::Effect::Handler::Mock.new do |effect, _context|
        ran << effect.name
        Lain::Tool::Result.ok("the interpreter ran")
      end
    end

    def parent_stack = Lain::CLI::ToolGuard.stack(chronicle, board)

    def parent_dispatch(name, input, ran = [])
      dispatch_call(name, input, toolset: board.toolset, layers: parent_stack.to_a, handler: recording(ran),
                                 context: Lain::Session.new)
    end

    def child_result(provider) = tool_results_of(provider.requests[1]).first

    def tool_results_of(request)
      request.messages.flat_map { |message| message["content"] }
                      .select { |block| block.is_a?(Hash) && block["type"] == "tool_result" }
    end

    def scripted(name, input) = mock(tool_response(["c1", name, input]), text_response("done"))

    # ---- Scenario: a child is gated by the same policy as its parent --------

    it "denies a child the tool its parent's policy denies, in the parent's own words" do
      board(attended: false)
      ran = []
      parent_told = parent_dispatch("bash", { "command" => "true" }, ran)
      provider = scripted("bash", { "command" => "true" })
      build, = wired(provider)

      build.role_spawn.call(:dev, :fresh, "go")

      expect(parent_told.content).to include("no approval is possible for tool \"bash\"")
      expect(ran).to be_empty
      expect(child_result(provider)).to include("is_error" => true, "content" => parent_told.content)
    end

    # ---- Scenario: a child's denial names the child -------------------------

    it "parks a child's gated call under the child's name, where the parent's parks under its own" do
      read = { "path" => "/home/tester/project/.env" }
      provider = scripted("read_file", read)
      _, toolset = wired(provider)

      asked = Sync do |task|
        parent_call = task.async { parent_dispatch("read_file", read) }
        parent_park = task.with_timeout(1) { board.approvals.dequeue }.tap { |pending| pending.deny(surface: "spec") }
        child_call = task.async { toolset.fetch("subagent").call({ "prompt" => "go" }, invocation) }
        child_park = task.with_timeout(1) { board.approvals.dequeue }.tap { |pending| pending.deny(surface: "spec") }
        parent_call.wait
        child_call.wait
        [parent_park, child_park]
      end

      expect(asked.map(&:requester)).to eq(%w[agent researcher])
      expect(asked.map(&:tool)).to eq(%w[read_file read_file])
      expect(child_result(provider))
        .to include("is_error" => true, "content" => %(approval denied for tool "read_file"))
    end

    # ---- Scenario: parent and child stacks come from one builder -------------

    it "hands the parent and a really spawned child the same layers, the gate last, over the one board" do
      agents = []
      allow(Lain::Agent).to receive(:new).and_wrap_original do |original, **kw|
        original.call(**kw).tap { |agent| agents << agent }
      end
      build, = wired(mock(text_response("done")))

      build.role_spawn.call(:dev, :fresh, "go")
      runner = agents.last.send(:tool_runner)
      child_layers = runner.middleware.to_a
      parent_layers = parent_stack.to_a

      expect(parent_layers.map(&:class))
        .to eq([Lain::Middleware::RefuseSecretWrites, Lain::Middleware::RedactSecretReads,
                Lain::Middleware::WithholdSecretPaths, Lain::Middleware::GuardTestLayout,
                Lain::Middleware::Sensitivity, Lain::Middleware::Gate])
      expect(child_layers.map(&:class)).to eq(parent_layers.map(&:class))
      expect(runner.handler).to be_a(Lain::Effect::Handler::Live)
      [parent_layers, child_layers].each do |layers|
        expect(layers.last.instance_variable_get(:@sensitivity)).to be(board.sensitivity)
        expect(layers.grep(Lain::Middleware::RedactSecretReads).first.ledger).to be(board.ledger)
      end
      expect(parent_layers.last.instance_variable_get(:@policy)).to be(board.policy_switch)
      expect(child_layers.last.instance_variable_get(:@policy).policy).to be(board.policy_switch)
    end
  end

  # ---- The Null defaults ----------------------------------------------------

  describe "an unwired seam" do
    it "gates nothing and attenuates nothing, so every existing spawn is unchanged" do
      provider = mock(*calls("bash"))
      build_subagent(provider:).call({ "prompt" => "go" }, invocation)

      expect(tools[:bash].runs.size).to eq(1)
      # "Unchanged" is about GATING and ATTENUATION, which is what this seam
      # wires nothing for. The `ask_human` beside them is a standing grant, which
      # every child holds and {Subagent::NoAskers} is the wired-to-nothing
      # answer for -- an asker whose question reaches no queue.
      expect(rendered(provider)).to eq((union.names + %w[ask_human]).sort)
    end

    # ---- Scenario: a seam with no stack builder is refused ------------------
    #
    # The gate rides the guard, so a seam holding no builder is a child with no
    # gate: refused where it is built, not discovered at the first spawn.
    it "refuses a seam whose tool middleware is not a builder at all" do
      expect do
        Lain::Tools::Subagent::Seam.new(provider: mock, context_factory: -> { child_context }, parent:,
                                        tool_middleware: nil)
      end.to raise_error(ArgumentError, /tool_middleware/)
    end

    # The likeliest wrong value is the stack itself: it answers `call`, so it
    # would pass as a builder and fail only at the first spawn, deep inside it.
    it "refuses a stack handed where a builder of one belongs, by name" do
      expect do
        Lain::Tools::Subagent::Seam.new(provider: mock, context_factory: -> { child_context }, parent:,
                                        tool_middleware: ToolRegistry::UNGUARDED.call(Lain::WorkerEnv.default))
      end.to raise_error(Lain::Tools::Subagent::NotABuilder, /tool_middleware must build/)
    end

    it "refuses a lone middleware handed where a builder belongs, by name" do
      expect do
        Lain::Tools::Subagent::Seam.new(provider: mock, context_factory: -> { child_context }, parent:,
                                        tool_middleware: Lain::Middleware::Gate.new)
      end.to raise_error(Lain::Tools::Subagent::NotABuilder)
    end

    it "is still a value: two all-default seams with the same members compare equal" do
      members = { provider: mock, context_factory: -> { child_context }, parent:,
                  tool_middleware: ToolRegistry::UNGUARDED }

      expect(Lain::Tools::Subagent::Seam.new(**members)).to eq(Lain::Tools::Subagent::Seam.new(**members))
    end
  end
end
