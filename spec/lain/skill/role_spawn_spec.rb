# frozen_string_literal: true

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
    expect(request.system.first["text"]).to eq(slots.render("system"))
    expect(request.system.first["cache"]).to be(true)
    expect(request.system.last["text"]).to eq(slots.render_role(:dev))
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
           tool_middleware: ->(worker_env) { ToolRegistry::UNGUARDED.call(worker_env).tap { seen << worker_env } })
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
end
