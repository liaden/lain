# frozen_string_literal: true

require "stringio"
require "tmpdir"

# A provider whose endpoint says, flatly, that it has not got the model asked
# about -- the one Serving answer that is a no. A named class and not an
# anonymous one, because the refusal names `provider.class` and a reader of the
# message has to be able to find it.
class RoleSpawnUnservingProvider < Lain::Provider::Mock
  def serves?(_model) = Lain::Provider::Serving::NOT_SERVED
end

# The call-time role-selecting spawn seam: (role_name, context_mode,
# prompt) -> subagent result. It fetches the role (loud on unknown, BEFORE any
# spawn), builds a one-shot Subagent under that role's policy and persona with
# the chosen prefix, and runs the prompt to a single final result synchronously.
RSpec.describe Lain::Skill::RoleSpawn do
  # A shared Store and a two-turn parent chain whose head is H -- the inherit
  # mode forks it, the fresh mode does not.
  let(:store) { Lain::Store.new }
  let(:parent) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                  .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
  end

  let(:child_context) { Lain::Context.new(model: "child-model", max_tokens: 256) }

  # The union a role attenuates FROM must hold every tool the role names, or
  # Toolset#only fails loudly. This is the dev role's full set (plus is fine).
  let(:union) do
    Lain::Toolset.new([
                        Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new, Lain::Tools::Glob.new,
                        Lain::Tools::Grep.new, Lain::Tools::EditFile.new, Lain::Tools::WriteFile.new,
                        Lain::Tools::TodoWrite.new, Lain::Tools::Bash.new
                      ])
  end

  around do |example|
    Dir.mktmpdir do |root|
      @slots = Lain::Prompt::Slots.load(root:)
      example.run
    end
  end

  attr_reader :slots

  def mock(*responses) = Lain::Provider::Mock.new(responses:)

  def seam(provider:, parent: self.parent, tool_middleware: ToolRegistry::UNGUARDED, **extra)
    described_class.new(
      provider:, context_factory: -> { child_context }, toolset: union, parent:, slots:, tool_middleware:, **extra
    )
  end

  # ---- The role's child runs behind the seam's tool guard ---------------------

  it "runs the chosen role's child through the seam's tool middleware" do
    seen = []
    guard = Class.new(Lain::Middleware::Base) do
      define_method(:call) do |env, &app|
        seen << env.fetch(:effect).name
        downstream(env, &app)
      end
    end.new
    provider = mock(tool_response(["r1", "read_file", { "path" => "/nowhere/at/all" }]), text_response("done"))

    seam(provider:, tool_middleware: ToolRegistry.guarded_by(guard)).call(:dev, :fresh, "go")

    expect(seen).to eq(["read_file"])
  end

  it "refuses loose seam members that name no tool middleware" do
    expect do
      described_class.new(provider: mock(text_response("unused")), context_factory: -> { child_context },
                          parent:, toolset: union, slots:)
    end.to raise_error(ArgumentError, /tool_middleware/)
  end

  # ---- The judge is told which role is asking --------------------------------

  describe "the requester a role's child asks under" do
    let(:asked) { [] }
    let(:identities) { [] }
    let(:policy) do
      Class.new do
        def initialize(asked, identities)
          @asked = asked
          @identities = identities
        end

        def call(effect, context) = rule(effect, context).allow?

        def rule(_effect, context)
          @asked << context.requester
          @identities << context.identity.to_s
          Lain::Approval::Escalation::Ruling.deny(rung: "spec", because: "not here")
        end
      end.new(asked, identities)
    end
    let(:inputs) do
      Lain::CLI::ToolGuard::Inputs.new(ledger: Lain::Sensitivity::Ledger.new, approvals: nil,
                                       sensitivity: Lain::Sensitivity::Policy::Null.instance,
                                       test_layout: Lain::Middleware::GuardTestLayout::Run.undeclared,
                                       policy:, policy_for: ->(_worker_env) { policy },
                                       denial: Lain::Middleware::Gate::DENIAL,
                                       bar: Lain::Middleware::WithholdAutomaticOutput::Bar.new)
    end
    let(:board) { Struct.new(:guard_inputs).new(inputs) }
    let(:spawned) do
      Lain::CLI::ToolGuard::Spawned.new(chronicle: Lain::CLI::ToolGuard::Journaled.new(journal: Lain::Channel::Null.instance),
                                        board: -> { board }, requester: "subagent")
    end

    it "names a role skill's child by its role, not as the run's subagent" do
      provider = mock(tool_response(["b1", "bash", { "command" => "make" }]), text_response("done"))

      seam(provider:, tool_middleware: spawned).call(:dev, :fresh, "go")

      expect(asked).to eq(["dev"])
    end

    it "names the skill a role's child runs under beside its role, keyed on the role alone" do
      provider = mock(tool_response(["b1", "bash", { "command" => "make" }]), text_response("done"))

      seam(provider:, tool_middleware: spawned).call(:dev, :fresh, "go", skill: "gherkin-tests")

      expect([asked, identities]).to eq([["dev"], ["dev (gherkin-tests)"]])
    end

    it "says the role once when no skill ran it" do
      provider = mock(tool_response(["b1", "bash", { "command" => "make" }]), text_response("done"))

      seam(provider:, tool_middleware: spawned).call(:dev, :fresh, "go")

      expect(identities).to eq(["dev"])
    end

    it "renames a Detached builder" do
      guard = Lain::CLI::ToolGuard.detached(journal: Lain::Channel::Null.instance)

      expect(seam(provider: mock(text_response("adjudicated")), tool_middleware: guard).call(:qa, :fresh, "go").content)
        .to eq("adjudicated")
    end

    # Epic submit's adjudication spawns this way: the never-parking copy of a
    # run with no chat, whose refusals are recorded under the child's role.
    it "names the role on a refusal through a Detached builder's never-parking copy" do
      journal_io = StringIO.new
      guard = Lain::CLI::ToolGuard.detached(journal: Lain::Journal.new(io: journal_io))
      provider = mock(tool_response(["b1", "bash", { "command" => "make" }]), text_response("done"))

      Sync { seam(provider:, tool_middleware: guard).never_parking.call(:dev, :fresh, "go") }

      expect(journal_records(journal_io, "escalation").map { |ruling| ruling["requester"] }).to eq(%w[dev])
    end

    it "leases no checkout for a never-parking child, whatever backend the run wired" do
      leased = []
      backend = Class.new do
        define_method(:acquire) do |worker_id|
          leased << worker_id
          Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.default, on_release: -> {})
        end
      end.new
      guard = Lain::CLI::ToolGuard.detached(journal: Lain::Channel::Null.instance)

      result = Sync do
        seam(provider: mock(text_response("ruled")), tool_middleware: guard,
             isolation: Lain::Isolation::Leases.new(backend:)).never_parking.call(:dev, :fresh, "go")
      end

      expect([result.content, leased]).to eq(["ruled", []])
    end

    it "runs a never-parking child in the directory current when it spawns, not when the seam was built" do
      seen = []
      builder = ToolRegistry.builder { |env, **| ToolRegistry::UNGUARDED.call(env).tap { seen << env.cwd } }

      Dir.mktmpdir do |first|
        Dir.mktmpdir do |second|
          current = Lain::WorkerEnv.default.with(cwd: File.realpath(first))
          spawn = seam(provider: mock(text_response("ruled")), tool_middleware: builder, worker_env: -> { current })
          current = Lain::WorkerEnv.default.with(cwd: File.realpath(second))
          spawn.never_parking.call(:dev, :fresh, "go")

          expect(seen).to eq([File.realpath(second)])
        end
      end
    end
  end

  # ---- The child runs under its role's iteration ceiling ---------------------

  describe "a child's iteration ceiling" do
    let(:search_union) do
      Lain::Toolset.new(union.to_a + [Lain::Tools::WebFetch.new, Lain::Tools::WebSearch.new])
    end

    def reads(count)
      Array.new(count) { |i| tool_response(["r#{i}", "read_file", { "path" => "/nowhere/at/all" }]) }
    end

    def spawn_over(role, calls)
      provider = mock(*reads(calls), text_response("finished"))
      seam(provider:, toolset: search_union).call(role, :fresh, "go")
    end

    it "lets a researcher run past the default ceiling" do
      expect(spawn_over(:researcher, 30).content).to eq("finished")
    end

    it "stops a role that declares no ceiling at 25 iterations" do
      expect { spawn_over(:dev, 30) }.to raise_error(Lain::Budget::Exceeded, /ceiling is 25/)
    end
  end

  # ---- A chosen role at call time, inherit prefix, persona in system ---------

  it "spawns the chosen role's only-set with an inherit prefix and the role persona in system" do
    provider = mock(text_response("done"))
    seam(provider:).call(:dev, :inherit, "go")

    request = provider.last_request

    # The dev only-set, rendered under the default schema posture -- plus the
    # `ask_human` granted to every child on top of its role's set, which no
    # role in the catalog names and every posture permits.
    expect(request.tools.map { |t| t["name"] })
      .to match_array(%w[read_file list_files glob grep edit_file write_file todo_write bash ask_human])

    # inherit prefix: the child forked the parent, so H's turns precede the prompt.
    expect(request.messages.first["content"].first["text"]).to eq("hi")

    # The dev persona reshaped the child's system into the two prelude segments.
    expect(request.system.size).to eq(2)
    expect(request.system.first["text"]).to eq(slots.render_child)
    expect(request.system.first["cache"]).to be(true)
    expect(request.system.last["text"]).to start_with(slots.render_role(:dev))
  end

  # ---- The fresh context mode -- no inherited parent conversation ------------

  it "honors the fresh context mode: the child inherits none of the parent's conversation" do
    provider = mock(text_response("done"))
    seam(provider:).call(:dev, :fresh, "go")

    request = provider.last_request
    texts = request.messages.flat_map { |m| Array(m["content"]).map { |b| b["text"] } }
    expect(texts).not_to include("hi", "yo")
    expect(request.messages.first["content"].first["text"]).to eq("go")
  end

  # ---- Run the prompt to a single final result, synchronously ----------------

  it "runs the prompt to a single final result, returned synchronously" do
    provider = mock(text_response("the final answer"))
    result = seam(provider:).call(:dev, :fresh, "compute it")

    expect(result).to be_ok
    expect(result.content).to eq("the final answer")
  end

  # ---- The model a spawn is bound to, per call -------------------------------

  describe "a model bound at the spawn" do
    def choice(model, declared_by: "skill :triage")
      Lain::Tools::Subagent::ModelChoice.of(model, declared_by:)
    end

    it "runs the child on the bound model, leaving the factory Context on the run's" do
      provider = mock(text_response("done"), text_response("done again"))
      spawn = seam(provider:)

      spawn.call(:dev, :fresh, "go", model: choice("claude-haiku-4"))
      bound = provider.last_request.model
      spawn.call(:dev, :fresh, "go again")

      expect(bound).to eq("claude-haiku-4")
      expect(provider.last_request.model).to eq("child-model")
      expect(child_context.model).to eq("child-model")
    end

    # A blank declaration has not chosen a model, so it must reach the spawn as
    # the Null and never as `with_model("")` -- a Request naming the empty
    # string is what an interning-but-not-refusing `.of` would render.
    it "keeps the run's model when nothing named one, blank included" do
      provider = mock(text_response("done"), text_response("done again"))
      spawn = seam(provider:)

      spawn.call(:dev, :fresh, "go")
      unbound = provider.last_request.model
      spawn.call(:dev, :fresh, "go again", model: choice(""))

      expect(unbound).to eq("child-model")
      expect(provider.last_request.model).to eq("child-model")
      expect(Lain::Tools::Subagent::ModelChoice.of("", declared_by: "skill :triage"))
        .to be(Lain::Tools::Subagent::ModelChoice::Null)
    end

    # `.of` is not the only door: `.new` and `#with` bypass it, so the interning
    # has to sit in the constructor or a caller's String stays reachable and a
    # later mutation follows the value into the bound Context.
    it "is deeply frozen however it was built, so a caller's String cannot follow it" do
      built = Lain::Tools::Subagent::ModelChoice.new(model: +"claude-haiku-4", declared_by: +"skill :triage")

      expect(built).to be_deeply_frozen
      expect(built.with(declared_by: +"the fleet")).to be_deeply_frozen
    end

    # The Null answers the readers as well as `bind`: the first caller logging
    # which model a rung got must not have to ask what type it is holding.
    it "answers a blank model and declarer from the Null, rather than refusing the readers" do
      null = Lain::Tools::Subagent::ModelChoice::Null

      expect([null.model, null.declared_by]).to eq(["", ""])
    end

    it "serves a caller's own choice through the same seam a skill's goes through" do
      provider = mock(text_response("done"))
      seam(provider:).call(:dev, :fresh, "go", model: choice("claude-haiku-4", declared_by: "the fleet"))

      expect(provider.last_request.model).to eq("claude-haiku-4")
    end

    it "refuses a model the run's provider says it has not got, naming all three, before any spawn" do
      provider = RoleSpawnUnservingProvider.new(responses: [text_response("never asked")])

      expect { seam(provider:).call(:dev, :fresh, "go", model: choice("gpt-5")) }
        .to raise_error(Lain::Tools::Subagent::ModelChoice::Unserved,
                        /skill :triage.*"gpt-5".*RoleSpawnUnservingProvider/m)
      expect(provider.call_count).to eq(0)
    end
  end

  # ---- SHOULD-FIX: the injected observer reaches the spawned child's Lineage -
  #
  # exe/lain wires the real Subagent with `observer: chronicle.observer` so the
  # child's :spawn/:message lineage reaches the session scribe. Once
  # `@role/skill` spawns are driven through this seam, an unforwarded observer
  # would land the child's lineage on the Null chain writer -- "silent record
  # loss one level up" (subagent.rb's own words). The seam must forward it.

  it "forwards an injected observer so the spawned child's spawn/message lineage reaches it" do
    seen = []
    provider = mock(text_response("done"))
    seam(provider:, observer: seen.method(:push)).call(:dev, :fresh, "go")

    # The funnel was widened: the child's OWN turns ride it between the two
    # lineage events, because the session record cannot reach them any other
    # way (a Timeline walk sees one chain, and the scribe's is the parent's).
    # Here that is the seeded user turn and the child's single reply.
    expect(seen.map(&:kind)).to eq(%i[spawn turn turn message])
  end

  describe "identical one-shot twins across calls" do
    def twin_addresses(count)
      seen = []
      spawn = seam(provider: mock(*Array.new(count) { text_response("done") }), observer: seen.method(:push),
                   twins: Lain::Tools::Subagent::Lineage::Twins.new)
      count.times { spawn.call(:dev, :fresh, "go") }
      seen.select { |event| event.kind == :spawn }.map(&:digest)
    end

    it "gives 2 identical calls 2 distinct addresses, though each call builds its own subagent" do
      expect(twin_addresses(2).uniq.size).to eq(2)
    end

    it "gives a replay over the same store, under a registry of its own, the same addresses" do
      expect(twin_addresses(2)).to eq(twin_addresses(2))
    end
  end

  # ---- An unknown role fails loudly, before any spawn ------------------------

  it "raises Role::Catalog::Unknown for an unknown role, spending no tokens" do
    provider = mock(text_response("unused"))
    subject_seam = seam(provider:)

    expect { subject_seam.call(:nope, :fresh, "go") }
      .to raise_error(Lain::Role::Catalog::Unknown, /nope.*expected one of/m)
    expect(provider.call_count).to eq(0)
  end

  # ---- A held checkout: the child runs where its caller already stands -------
  #
  # A caller holding a lease -- an issue's actor, its checkout cut and on its
  # branch -- lends it to the spawn, so the child writes where the caller will
  # commit, and no second checkout is cut for the same work.
  describe "a role spawn within a held environment" do
    let(:seen) { [] }

    # Counts every lease the spawn lane takes, each over the host directory.
    let(:backend) do
      Class.new do
        def acquired = @acquired ||= []

        def acquire(worker_id)
          acquired << worker_id
          Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.default, on_release: -> {})
        end
      end.new
    end

    # The tool guard is built once per child over the environment that child
    # runs in, so recording it is recording where the child stands.
    def watched(provider:)
      seam(provider:, isolation: Lain::Isolation::Leases.new(backend:),
           tool_middleware: ToolRegistry.builder { |env, **| ToolRegistry::UNGUARDED.call(env).tap { seen << env } })
    end

    def tool_results(request)
      request.messages.flat_map { |message| Array(message["content"]) }
             .select { |block| block.is_a?(Hash) && block["type"] == "tool_result" }
             .map { |block| block["content"].to_s }
    end

    it "runs the child in the held checkout, and takes no lease of its own" do
      Dir.mktmpdir do |held|
        File.write(File.join(held, "held.txt"), "written in the held checkout\n")
        provider = mock(tool_response(["r1", "read_file", { "path" => "held.txt" }]), text_response("done"))

        result = watched(provider:).within(Lain::WorkerEnv.default.with(cwd: held)).call(:test_engineer, :fresh, "go")

        expect(result).to be_ok
        expect(backend.acquired).to be_empty
        expect(seen.map(&:cwd)).to eq([held])
        expect(tool_results(provider.last_request).join).to include("written in the held checkout")
      end
    end

    it "leaves a spawn with no held environment leasing as before, in the session's own directory" do
      watched(provider: mock(text_response("done"))).call(:test_engineer, :fresh, "go")

      expect(backend.acquired.size).to eq(1)
      expect(seen.map(&:cwd)).to eq([Dir.pwd])
    end

    # The lane rides the lineage, so a lent child's spawn says which issue it
    # belonged to rather than reading as the run's own unnamed lane.
    it "keeps the caller's lane, so a lent child's lineage names the issue it served" do
      lane = Lain::Isolation::Leases::Lane.named("issue.demo.a.1")
      spawn = seam(provider: mock(text_response("unused")),
                   isolation: Lain::Isolation::Leases.new(backend:, lane:))

      expect(spawn.within(Lain::WorkerEnv.default).seam.isolation.lane).to eq(lane)
    end

    it "lends a lane of its own when told one, so a retry's children differ from the first attempt's" do
      spawn = seam(provider: mock(text_response("unused")), isolation: Lain::Isolation::Leases.new(backend:))
      lent = spawn.within(Lain::WorkerEnv.default, lane: "issue.demo.a.2")

      expect(lent.seam.isolation.lane).to eq(Lain::Isolation::Leases::Lane.named("issue.demo.a.2"))
    end

    it "refuses a lane name git would not accept in a ref" do
      spawn = seam(provider: mock(text_response("unused")))

      expect { spawn.within(Lain::WorkerEnv.default, lane: "bad lane~") }
        .to raise_error(Lain::Isolation::Leases::Lane::Refused)
    end

    # The epic driver lends its children a held checkout through here, and a
    # lent :inherit child still renders the parent's held cut.
    it "keeps the parent's held cuts for a lent :inherit child" do
      session = Lain::Session.new.record_compaction_cut(
        Lain::Telemetry::CompactionCut.new(
          digest: parent.head_digest, head: parent.head_digest, strategy: Lain::Telemetry::Compaction::EAGER_CONTROL_ARM,
          kind: "handoff", parent: nil, supersedes: [], plan_step_completions: 0,
          collapses: [{ "span" => [parent.to_a.first.digest, parent.head_digest],
                        "content" => [{ "type" => "text", "text" => "STATE-DOCUMENT" }] }]
        )
      )
      source = lambda do
        Lain::Compaction::Source.new(
          need: Lain::Compaction::Need.new(byte_threshold: 1_000_000),
          cold: Lain::Compaction::Cold.new(cache_profile: Lain::CacheProfile::NO_CACHING, journal: []),
          hard_cap: 1_000_000, keep_last: 20, context_window: Lain::ContextWindow.new(windows: { "child" => 8192 })
        )
      end
      provider = mock(text_response("done"))
      arm = Lain::Telemetry::Compaction::EAGER_CONTROL_ARM
      view = Lain::Tools::Subagent::ParentView.new(session:, arm:, source:)
      spawn = seam(provider:, compaction: view)

      spawn.within(Lain::WorkerEnv.default).call(:test_engineer, :inherit, "go")

      sent = Lain::Canonical.dump(provider.last_request.messages)
      expect(sent).to include("STATE-DOCUMENT")
      expect(sent).not_to include('"hi"')
    end

    it "leaves the seam it was built over leasing as it did" do
      spawn = watched(provider: mock(text_response("unused")))

      expect(spawn.within(Lain::WorkerEnv.default).seam.isolation).not_to be(spawn.seam.isolation)
      expect(spawn.seam.isolation).to be_a(Lain::Isolation::Leases)
    end
  end

  # ---- One Seam held, and per-call work that is role selection only ----------
  #
  # This class's own doc already says it "holds the same collaborator set the
  # exe's research_subagent assembles" -- the same six, written out twice. Held
  # as one value, what is FIXED at construction and what is CHOSEN per call stop
  # being interleaved in one nine-keyword signature.
  #
  # Every other example above constructs with the loose keywords, so their green
  # beside this block's is the additive claim: both styles are valid.
  describe "the spawn Seam" do
    def seam_value(provider:, **extra)
      Lain::Tools::Subagent::Seam.new(provider:, context_factory: -> { child_context }, parent:,
                                      tool_middleware: ToolRegistry::UNGUARDED, **extra)
    end

    it "spawns over an injected seam, holding no loose collaborators of its own" do
      value = seam_value(provider: mock(text_response("done")))
      spawn = described_class.new(seam: value, toolset: union, slots:)

      expect(spawn.call(:dev, :fresh, "go")).to be_ok
      expect(spawn.seam).to be(value)
    end

    # The role is the per-call variable; the seam is not. Two calls through one
    # instance pick two different only-sets while every collaborator -- here the
    # observer carrying each child's lineage -- stays the same object.
    it "chooses the role per call and leaves the held seam untouched" do
      seen = []
      provider = mock(text_response("a"), text_response("b"))
      spawn = described_class.new(seam: seam_value(provider:, observer: seen.method(:push)),
                                  toolset: union, slots:)

      spawn.call(:dev, :fresh, "one")
      dev_tools = provider.last_request.tools.map { |tool| tool["name"] }
      spawn.call(:reviewer_sre, :fresh, "two")

      expect(provider.last_request.tools.map { |tool| tool["name"] })
        .to match_array(%w[read_file list_files bash ask_human])
      expect(dev_tools.size).to eq(9)
      expect(seen.map(&:kind)).to eq(%i[spawn turn turn message spawn turn turn message])
    end

    it "refuses a seam and its loose members together, naming the member" do
      provider = mock(text_response("unused"))

      expect { described_class.new(seam: seam_value(provider:), provider:, toolset: union, slots:) }
        .to raise_error(ArgumentError, "pass seam: or its members [:provider], not both")
    end

    it "refuses a loose keyword that is not a seam member" do
      expect do
        described_class.new(provider: mock(text_response("unused")), context_factory: -> { child_context },
                            parent:, tool_middleware: ToolRegistry::UNGUARDED, observers: [],
                            toolset: union, slots:)
      end.to raise_error(ArgumentError, /unknown keyword: :observers/)
    end

    # A typo beside a seam is a typo, not a both-at-once conflict.
    it "calls a misspelled keyword beside a seam a typo, not a conflict" do
      expect do
        described_class.new(seam: seam_value(provider: mock(text_response("unused"))),
                            toolset: union, slots:, max_dept: 2)
      end.to raise_error(ArgumentError, "unknown keyword: :max_dept")
    end
  end

  # ---- A role placed in a kept directory of its own ---------------------------
  #
  # The chat's researcher keeps a lease on every route, so a role skill that
  # names it spawns over the researcher's own seam and into its own directory.
  describe "a role with a place of its own" do
    let(:base_seen) { [] }
    let(:placed_seen) { [] }
    let(:researcher_union) do
      Lain::Toolset.new(union.to_a + [Lain::Tools::WebFetch.new, Lain::Tools::WebSearch.new])
    end

    def recording(into) = ToolRegistry.builder { |env, **| ToolRegistry::UNGUARDED.call(env).tap { into << env } }

    def kept(root)
      Lain::Tools::Subagent::Kept.new(root:, paths: Lain::Paths.new(env: { "HOME" => root }), related: ->(_) { false },
                                      scratch: Lain::Isolation::Scratch.new(root:, prefix: "research-"))
    end

    def placed_spawn(provider, root)
      place = described_class::Placed.new(
        seam: Lain::Tools::Subagent::Seam.new(provider:, context_factory: -> { child_context }, parent:,
                                              tool_middleware: recording(placed_seen)),
        kept: kept(root)
      )
      seam(provider:, toolset: researcher_union, tool_middleware: recording(base_seen), placed: { researcher: place })
    end

    it "spawns the placed role in a kept directory of its own, over its place's seam" do
      Dir.mktmpdir do |root|
        provider = mock(tool_response(["r1", "read_file", { "path" => "/nowhere/at/all" }]), text_response("done"))

        placed_spawn(provider, File.realpath(root)).call(:researcher, :fresh, "go")
        dir = placed_seen.map(&:cwd).first

        expect(base_seen).to be_empty
        expect(dir).to start_with(File.join(File.realpath(root), "research-"))
        expect(provider.requests.first.system.last["text"]).to end_with("Working directory: #{dir}")
      end
    end

    it "leaves a role with no place spawning over the held seam" do
      Dir.mktmpdir do |root|
        provider = mock(tool_response(["r1", "read_file", { "path" => "/nowhere/at/all" }]), text_response("done"))

        placed_spawn(provider, root).call(:dev, :fresh, "go")

        expect(placed_seen).to be_empty
        expect(base_seen.size).to eq(1)
      end
    end

    # The never-parking guard holds no child in a lease, so a placed role
    # refuses there rather than running unconfined.
    it "refuses a placed role through never_parking, before any spawn" do
      Dir.mktmpdir do |root|
        provider = mock(text_response("unused"))
        spawn = placed_spawn(provider, root)

        expect { spawn.never_parking.call(:researcher, :fresh, "go") }
          .to raise_error(described_class::Refused, /researcher/)
        expect(provider.requests).to be_empty
      end
    end

    # The requester names whoever the child is, so a refusal in its journal
    # blames the right role rather than the first approval role that was built.
    it "names each never-parking child by its own role" do
      named = []
      parked = Class.new do
        define_method(:with) { |requester:| (named << requester.name) && self }
        def call(worker_env, **) = ToolRegistry::UNGUARDED.call(worker_env)
      end.new
      guard = ->(worker_env, **) { ToolRegistry::UNGUARDED.call(worker_env) }
      guard.define_singleton_method(:never_parking) { parked }
      wide = Lain::Toolset.new(union.to_a + [Lain::Tools::WebFetch.new, Lain::Tools::WebSearch.new])
      roles = %i[auto_approver gate_adjudicator evidence_researcher]

      roles.each do |role|
        described_class.new(provider: mock(text_response("done")), context_factory: -> { child_context },
                            toolset: wide, parent:, slots:, tool_middleware: guard)
                       .never_parking.call(role, :fresh, "go")
      end

      expect(named).to eq(roles.map(&:to_s))
    end

    it "refuses a placed role's lease under never_parking, whichever member is read first" do
      expect { described_class::Unplaceable.new(:researcher).kept }
        .to raise_error(described_class::Refused, /researcher/)
    end

    it "keeps the placed role in its own directory within a held environment" do
      Dir.mktmpdir do |root|
        provider = mock(tool_response(["r1", "read_file", { "path" => "/nowhere/at/all" }]), text_response("done"))

        placed_spawn(provider, File.realpath(root)).within(Lain::WorkerEnv.default).call(:researcher, :fresh, "go")

        expect(placed_seen.map(&:cwd)).to contain_exactly(start_with(File.join(File.realpath(root), "research-")))
      end
    end
  end
end
