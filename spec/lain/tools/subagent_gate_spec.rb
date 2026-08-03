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

# T11: a child spawned by the subagent tool runs behind the SAME approval gate
# its parent does. Until this landed, `bash` was gated for the parent and
# ungated for every child holding it -- and four shipped roles hold it.
#
# The two axes the parent's posture governs arrive on the spawn {Seam} and
# nowhere else: `gate_policy` (what a tier-3 call must pass) and `permits`
# (which capabilities the posture lets a child hold at all). Both default to
# Null Objects, so an unwired spawn behaves exactly as it did before.
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

  def mock(*responses) = Lain::Provider::Mock.new(responses:)

  def seam(provider:, **over)
    Lain::Tools::Subagent::Seam.new(provider:, context_factory: -> { child_context }, parent:, journal:, **over)
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

  # ---- Scenario: a child in plan posture cannot hold bash at all -------------

  describe "a parent in plan" do
    let(:permits) { Lain::Mode::Posture.for(:plan).permits }

    it "spawns a dev child whose rendered toolset does not include bash" do
      provider = mock(text_response("done"))
      build_subagent(provider:, permits:).call({ "prompt" => "go" }, invocation)

      expect(rendered(provider)).not_to include("bash")
    end

    it "keeps every capability the posture does permit" do
      provider = mock(text_response("done"))
      build_subagent(provider:, permits:).call({ "prompt" => "go" }, invocation)

      expect(rendered(provider)).to eq(%w[ask_human glob grep list_files read_file])
    end

    # `:merge_resolver`'s four names are not a superset of the posture's set, and
    # the posture must ANSWER that rather than raise: `Permits#attenuate` goes
    # through {Toolset#only}, which would die on the nine read-only names this
    # child never held.
    it "attenuates a role whose set the posture's does not cover, without raising" do
      provider = mock(text_response("done"))

      expect { build_subagent(provider:, role: :merge_resolver, permits:).call({ "prompt" => "go" }, invocation) }
        .not_to raise_error
      expect(rendered(provider)).to eq(%w[ask_human grep read_file])
    end

    # A child with nothing at all is a wiring error, not a tighter child. It is
    # unreachable from the catalog -- every built-in role holds `read_file`,
    # which every posture permits -- so the probe pairs a custom `only:` with a
    # posture that shares no name with it, which is the only way a reader
    # arrives here.
    it "refuses to spawn a child the posture would leave holding nothing" do
      tool = Lain::Tools::Subagent.new(
        seam: seam(provider: mock(text_response("done")), permits:), toolset: union,
        policy: Lain::Tool::SpawnPolicy.new(only: %i[bash]),
        budget: Lain::Agent::Budget.new, max_depth: 1
      )

      expect { tool.call({ "prompt" => "go" }, invocation) }
        .to raise_error(Lain::Tools::Subagent::NoCapability, /permits none of the spawn's tools \(bash\)/)
    end

    it "leaves the child's set alone under an unattenuating posture" do
      provider = mock(text_response("done"))
      build_subagent(provider:, permits: Lain::Mode::Posture.for(:manual).permits)
        .call({ "prompt" => "go" }, invocation)

      expect(rendered(provider)).to eq((union.names + %w[ask_human]).sort)
    end
  end

  # ---- Scenario: the merge_resolver role still runs unattended ---------------

  describe "an unattended role under a parent in accept_edits" do
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
      tool = build_subagent(provider: mock(*calls("bash")), gate_policy: Lain::Effect::Handler::Gate::DenyAll.new)
      result = tool.call({ "prompt" => "go" }, invocation)

      expect(result.is_error).to be(false)
      refusal = tool_results(tool.last_child).first
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
      expect(tool_results(tool.last_child).first["is_error"]).to be(true)
    end

    it "still gates a call the child WAS attenuated to" do
      policy = SubagentGateSupport::SpyPolicy.new(verdict: false)
      tool = build_subagent(provider: mock(*calls("bash")), posture: :handler_union, gate_policy: policy)
      tool.call({ "prompt" => "go" }, invocation)

      expect(policy.asked).to eq(%w[bash])
      expect(tools[:bash].runs).to be_empty
    end
  end

  # ---- The Null defaults ----------------------------------------------------

  describe "an unwired seam" do
    it "gates nothing and attenuates nothing, so every existing spawn is unchanged" do
      provider = mock(*calls("bash"))
      build_subagent(provider:).call({ "prompt" => "go" }, invocation)

      expect(tools[:bash].runs.size).to eq(1)
      # "Unchanged" is about GATING and ATTENUATION, which is what this seam
      # wires nothing for. The `ask_human` beside them is T10's grant, which
      # every child holds and {Subagent::NoAskers} is the wired-to-nothing
      # answer for -- an asker whose question reaches no queue.
      expect(rendered(provider)).to eq((union.names + %w[ask_human]).sort)
    end

    it "is still a value: two all-default seams with the same members compare equal" do
      members = { provider: mock, context_factory: -> { child_context }, parent: }

      expect(Lain::Tools::Subagent::Seam.new(**members)).to eq(Lain::Tools::Subagent::Seam.new(**members))
    end
  end
end
