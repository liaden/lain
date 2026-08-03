# frozen_string_literal: true

require "async"
require "tmpdir"
require "timeout"

RSpec.describe Lain::Tools::Subagent do
  # A shared Store, and a two-turn parent chain whose head is H.
  let(:store) { Lain::Store.new }
  let(:parent) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                  .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
  end

  # The union the child attenuates from: an allowed tool (read_file) and a
  # disallowed one (echo). `only(:read_file)` is the attenuation under test.
  let(:union) { Lain::Toolset.new([Lain::Tools::ReadFile.new, EchoTool.new]) }
  let(:child_context) { Lain::Context.new(model: "child-model", max_tokens: 256) }
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }

  def spawn_policy(prefix: :fresh, posture: :schema, only: %i[read_file])
    Lain::Tool::SpawnPolicy.new(prefix:, posture:, only:)
  end

  def build_subagent(provider:, policy: spawn_policy, parent: self.parent,
                     journal: Lain::Channel::Null.instance, max_depth: 3, toolset: union)
    described_class.new(
      provider:, context_factory: -> { child_context }, toolset:, policy:,
      parent:, journal:, budget: Lain::Agent::Budget.new, max_depth:
    )
  end

  def mock(*responses)
    Lain::Provider::Mock.new(responses:)
  end

  # Every child now holds an `ask_human` of its OWN (T10), granted at the spawn
  # rather than inherited from the union it attenuates from -- so a rendered
  # tools block is the set under test PLUS that one, in {Toolset}'s sorted
  # order. Said once here, because the alternative is nine call sites each
  # restating a capability none of them is about.
  def with_asker(*names) = (names.flatten + %w[ask_human]).sort

  # The through-the-loop shape: a real parent Agent whose toolset holds the
  # subagent, late-bound through a thunk (the toolset is built before the
  # Agent, exactly the exe wiring). Returns [tool, parent_agent], settled.
  def loop_driven(child_provider:)
    parent_agent = nil
    tool = build_subagent(provider: child_provider, parent: -> { parent_agent.timeline })
    parent_agent = loop_parent(tool)
    parent_agent.ask("please spawn")
    [tool, parent_agent]
  end

  def loop_parent(tool)
    Lain::Agent.new(
      provider: mock(tool_response(["call_1", "subagent", { "prompt" => "go" }]), text_response("parent done")),
      toolset: Lain::Toolset.new([tool]),
      context: Lain::Context.new(model: "parent", max_tokens: 256),
      timeline: Lain::Timeline.empty(store:)
    )
  end

  it "has a model-facing name and description" do
    tool = build_subagent(provider: mock(text_response))
    expect(tool.name).to eq("subagent")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  # ---- Scenario: fresh root over the shared Store (5-1.1) --------------------

  describe "fresh-root spawn" do
    it "gives the child no parent turn, an empty meet, and a :spawn event with a causal edge to H" do
      tool = build_subagent(provider: mock(text_response("did the thing")))
      result = tool.call({ "prompt" => "go" }, invocation)

      expect(result).to be_ok

      child = tool.last_child
      expect(child.include?(parent.head_digest)).to be(false)
      expect(child.meet(parent)).to be_empty

      spawn = tool.last_spawn
      expect(spawn.kind).to eq(:spawn)
      expect(spawn.causal_parents).to include(parent.head_digest)
    end
  end

  # ---- Scenario: the return is an ordinary tool_result (5-1.1) ---------------

  describe "the child's result comes back as a tool_result" do
    it "returns the final text, and a :message event names the :spawn and F among its causal parents" do
      tool = build_subagent(provider: mock(text_response("child answer")))
      result = tool.call({ "prompt" => "go" }, invocation)

      expect(result).to be_ok
      expect(result.content).to eq("child answer")

      final = tool.last_child.head_digest
      message = tool.last_message
      expect(message.kind).to eq(:message)
      expect(message.causal_parents).to include(tool.last_spawn.digest)
      expect(message.causal_parents).to include(final)
    end

    # Gate 2 survives a real nested spawn: the parent Agent, running the subagent
    # as an ordinary tool, still lands the child's result in ONE user turn.
    it "lands in a single parent user turn when driven through the parent's loop (gate 2 intact)" do
      _tool, parent_agent = loop_driven(child_provider: mock(text_response("child answer")))

      turns = parent_agent.timeline.to_a
      expect(turns.map(&:role)).to eq(%w[user assistant user assistant])
      results_turn = turns[2]
      expect(results_turn.content.map { |b| b["type"] }).to eq(%w[tool_result])
      expect(results_turn.content.first["content"]).to eq("child answer")
      expect(results_turn.content.first["is_error"]).to be(false)
    end
  end

  # ---- Provenance at correlation grain (panel ruling) -------------------------

  describe "provenance at correlation grain" do
    # Ruling (T19 panel): the parent's rendered tool_result turn keeps
    # causal_parents [] -- ToolRunner and Timeline#commit stay out of this card.
    # The child is reachable at CORRELATION grain instead: message.to names the
    # parent chain's correlation (its root event digest), and the causal walk
    # descends from there to the :spawn and the child's final turn F. The
    # edge-grain gap is recorded in the plan for the M5 tail.
    it "finds :spawn, :message, and F from the parent's settled state by correlation" do
      tool, parent_agent = loop_driven(child_provider: mock(text_response("child answer")))

      correlation = parent_agent.timeline.to_a.first.digest
      message = tool.last_message
      expect(message.to).to eq(correlation)
      expect(message.correlation).to eq(correlation)

      spawn = tool.last_spawn
      expect(spawn.correlation).to eq(correlation)
      expect(message.causal_parents).to include(spawn.digest)

      final = store.fetch(message.body.fetch("final"))
      expect(final.digest).to eq(tool.last_child.head_digest)

      # The rendered tool_result turn itself carries no causal edge (ruling).
      expect(parent_agent.timeline.to_a[2].causal_parents).to eq([])
    end
  end

  # ---- Scenario: attenuation under each posture (5-1.2) ----------------------

  describe "attenuation postures" do
    it "schema posture: the child renders only the allowed tool's schema" do
      provider = mock(text_response("done"))
      tool = build_subagent(provider:, policy: spawn_policy(posture: :schema))
      tool.call({ "prompt" => "go" }, invocation)

      rendered = provider.last_request.tools.map { |t| t["name"] }
      expect(rendered).to eq(with_asker("read_file"))
    end

    # handler_union: the child's rendered tools block equals the SHARED UNION --
    # sibling-equality is the CE-4 win (two siblings spawned from this union
    # render byte-identical tools blocks) -- NOT "the parent's own toolset",
    # which may differ (in exe the parent holds base + subagent; the union
    # handed to the tool is base).
    it "handler_union posture: renders the shared union, refuses a disallowed call, and journals the refusal" do
      provider = mock(
        tool_response(["t1", "echo", { "text" => "x" }]),
        text_response("done")
      )
      journal = Lain::Channel.new
      tool = build_subagent(provider:, policy: spawn_policy(posture: :handler_union), journal:)
      tool.call({ "prompt" => "go" }, invocation)

      rendered = provider.requests.first.tools.map { |t| t["name"] }
      expect(rendered).to eq(with_asker(union.names))

      refusal_turn = tool.last_child.to_a.find do |turn|
        turn.role == "user" && turn.content.any? { |b| b["type"] == "tool_result" }
      end
      expect(refusal_turn.content.first["is_error"]).to be(true)

      journaled = journal.drain.map { |event| event.to_journal["type"] }
      expect(journaled).to include("refused")
    end
  end

  # ---- Scenario: inherit is O(1) (5-1.3) ------------------------------------

  describe "inherit prefix" do
    it "starts the child from the parent's head, so its history includes H" do
      tool = build_subagent(provider: mock(text_response("done")), policy: spawn_policy(prefix: :inherit))
      tool.call({ "prompt" => "go" }, invocation)

      expect(tool.last_child.include?(parent.head_digest)).to be(true)
    end
  end

  # ---- Scenario: the sibling-template prefix (CE-4 arm) ----------------------

  describe "sibling-template prefix" do
    let(:template) { "You are one of a set of sibling workers over one shared brief. " * 20 }

    def sibling_template_policy(template, posture: :handler_union, only: %i[read_file])
      Lain::Tool::SpawnPolicy.new(
        prefix: Lain::Tool::SpawnPolicy::PrefixStrategy::SiblingTemplate.new(template:),
        posture:, only:
      )
    end

    def cache_marks(request)
      system_marks = (request.system || []).select { |b| b["cache"] }
      message_marks = request.messages.flat_map { |m| m["content"] }.select { |b| b.is_a?(Hash) && b["cache"] }
      [system_marks, message_marks]
    end

    it "gives three siblings a byte-identical prefix through the template breakpoint, per-child content after it" do
      provider = mock(text_response("one"), text_response("two"), text_response("three"))
      tool = build_subagent(provider:, policy: sibling_template_policy(template))

      %w[alpha beta gamma].each { |task| expect(tool.call({ "prompt" => task }, invocation)).to be_ok }

      requests = provider.requests
      expect(requests.size).to eq(3)

      # The shared prefix (tools + system) is byte-identical across siblings...
      expect(requests.map { |r| Lain::Canonical.dump(r.cache_prefix) }.uniq.size).to eq(1)

      # ...so the digest chains share their head, and it sits at the system
      # marker -- the template breakpoint.
      heads = requests.map { |r| r.prefix_digests.first }
      expect(heads.uniq.size).to eq(1)
      expect(heads.first.first).to eq(Lain::Request::SYSTEM_PREFIX)

      # Per-child content lands AFTER the breakpoint: each task is its own
      # first user message, and the chains diverge there.
      %w[alpha beta gamma].each_with_index do |task, index|
        expect(requests[index].messages.first["content"].first["text"]).to eq(task)
      end
      expect(requests.map { |r| r.prefix_digests.last }.uniq.size).to eq(3)
    end

    # The T24 5-mark-400 pin: count ALL marks that reach the wire, across
    # system AND messages. Exactly one system mark -- Context#cache_marked's,
    # landing ON the template because the strategy leaves it as the last,
    # unmarked block -- plus CacheBreakpoints' marks on messages. A second
    # system mark would overrun Anthropic's 4-marker cap once CacheBreakpoints
    # spends its 3-message budget.
    it "sends exactly the intended marks: one on the template block, the rest CacheBreakpoints' own" do
      provider = mock(text_response("done"))
      tool = build_subagent(provider:, policy: sibling_template_policy(template))
      tool.call({ "prompt" => "go" }, invocation)

      system_marks, message_marks = cache_marks(provider.last_request)
      expect(system_marks.size).to eq(1)
      expect(system_marks.first["text"]).to eq(template)
      expect(message_marks.size).to eq(1)
    end

    it "renders all three prefix strategies through the same Context seam" do
      strategies = {
        fresh: :fresh, inherit: :inherit,
        sibling_template: Lain::Tool::SpawnPolicy::PrefixStrategy::SiblingTemplate.new(template:)
      }

      systems = strategies.transform_values do |prefix|
        provider = mock(text_response("done"))
        tool = build_subagent(provider:, policy: spawn_policy(prefix:))
        expect(tool.call({ "prompt" => "go" }, invocation)).to be_ok
        expect(provider.last_request.model).to eq("child-model")
        provider.last_request.system
      end

      # Same seam, one divergence: only the template arm reshapes system.
      expect(systems[:fresh]).to be_nil
      expect(systems[:inherit]).to be_nil
      expect(systems[:sibling_template].last["text"]).to eq(template)
    end

    it "handler_union keeps sibling tool schemas byte-identical, refusing per child at the Handler" do
      provider = mock(
        text_response("first done"),
        tool_response(["t1", "echo", { "text" => "x" }]),
        text_response("second done")
      )
      journal = Lain::Channel.new
      tool = build_subagent(provider:, policy: sibling_template_policy(template), journal:)

      expect(tool.call({ "prompt" => "one" }, invocation)).to be_ok
      expect(tool.call({ "prompt" => "two" }, invocation)).to be_ok

      # Every sibling request carries the same union schema bytes (position-0
      # sharing preserved)...
      expect(provider.requests.map { |r| Lain::Canonical.dump(r.tools) }.uniq.size).to eq(1)
      expect(provider.requests.first.tools.map { |t| t["name"] }).to eq(with_asker(union.names))

      # ...and the second child's disallowed echo was refused at the Handler.
      refusal = tool.last_child.to_a.find do |turn|
        turn.role == "user" && turn.content.any? { |b| b["type"] == "tool_result" }
      end
      expect(refusal.content.first["is_error"]).to be(true)
      expect(journal.drain.map { |event| event.to_journal["type"] }).to include("refused")
    end

    # The floor scenario: a template under the minimum cacheable prefix is
    # REPORTED (a journaled note per spawn), never silently un-cacheable.
    it "journals a template_below_floor note when the template sits under the floor" do
      journal = Lain::Channel.new
      tool = build_subagent(provider: mock(text_response("done")),
                            policy: sibling_template_policy("tiny brief"), journal:)
      tool.call({ "prompt" => "go" }, invocation)

      expect(journal.drain.map { |event| event.to_journal["type"] }).to include("template_below_floor")
    end

    # The strip rides the spawn seam's own journal: a factory that hands over a
    # pre-marked system (the role_spec probe shape) gets exactly one wire mark
    # -- on the template -- and the discarded caller mark lands in the record.
    it "threads the strip note through the spawn seam when the factory context arrives pre-marked" do
      marked_context = Lain::Context.new(
        model: "child-model", max_tokens: 256,
        system: [{ "type" => "text", "text" => "bulk", "cache" => true }]
      )
      journal = Lain::Channel.new
      provider = mock(text_response("done"))
      tool = described_class.new(
        provider:, context_factory: -> { marked_context }, toolset: union,
        policy: sibling_template_policy(template), parent:, journal:
      )
      expect(tool.call({ "prompt" => "go" }, invocation)).to be_ok

      system_marks, = cache_marks(provider.last_request)
      expect(system_marks.size).to eq(1)
      expect(system_marks.first["text"]).to eq(template)
      expect(journal.drain.map { |event| event.to_journal["type"] }).to include("system_mark_stripped")
    end

    it "journals no floor note when the template clears the minimum cacheable prefix" do
      floor = Lain::Tool::SpawnPolicy::PrefixStrategy::SiblingTemplate::MINIMUM_CACHEABLE_TOKENS *
              Lain::Tool::SpawnPolicy::PrefixStrategy::SiblingTemplate::CHARS_PER_TOKEN
      journal = Lain::Channel.new
      tool = build_subagent(provider: mock(text_response("done")),
                            policy: sibling_template_policy("x" * floor), journal:)
      tool.call({ "prompt" => "go" }, invocation)

      expect(journal.drain.map { |event| event.to_journal["type"] }).not_to include("template_below_floor")
    end

    # AC4 has no lifecycle exemption: an actor-mode sibling below the floor
    # must be reported through #launch_actor's path exactly as a one-shot's is
    # through #perform's -- silence here is the un-cacheable fan-out the note
    # exists to expose.
    it "journals the floor note on an actor-mode launch too" do
      journal = Lain::Channel.new
      tool = described_class.new(
        provider: mock(text_response("actor done")), context_factory: -> { child_context },
        toolset: union, policy: sibling_template_policy("tiny"), parent:, journal:,
        mode: :actor, log: Lain::Tools::Subagent::Log.new
      )
      Sync do
        actor = tool.launch_actor("go")
        actor.settle
        actor.stop
      end

      expect(journal.drain.map { |event| event.to_journal["type"] }).to include("template_below_floor")
    end
  end

  # ---- T-D1: the injected role persona reshapes the child system (PS-3) ------
  #
  # The persona is a NEW injected collaborator ({Role::Persona}); its Null
  # default keeps every existing spawn path byte-identical. The full persona
  # acceptance (segment sharing, override reach, fused-String failure) lives in
  # spec/lain/role_prelude_wiring_spec.rb; these two pin the seam's presence and
  # its Null default here, beside the tool.
  describe "the injected role persona (PS-3)" do
    it "defaults to Null: with no persona wired the child's system is unchanged" do
      provider = mock(text_response("done"))
      build_subagent(provider:).call({ "prompt" => "go" }, invocation)

      # child_context carries system: nil, and the Null persona is identity.
      expect(provider.last_request.system).to be_nil
    end

    it "reshapes the child system to the role prelude segments when a persona is wired" do
      Dir.mktmpdir do |root|
        slots = Lain::Prompt::Slots.load(root:)
        role = Lain::Role::Catalog.fetch(:researcher)
        read_union = Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new,
                                        Lain::Tools::WebFetch.new, Lain::Tools::WebSearch.new])
        provider = mock(text_response("done"))
        tool = described_class.new(
          provider:, context_factory: -> { child_context }, toolset: read_union,
          policy: role.spawn_policy, parent:, persona: Lain::Role::Persona.new(role:, slots:)
        )

        tool.call({ "prompt" => "go" }, invocation)

        system = provider.last_request.system
        expect(system.size).to eq(2)
        expect(system.first["text"]).to eq(slots.render("system"))
        expect(system.first["cache"]).to be(true)
        expect(system.last["text"]).to eq(slots.render_role(:researcher))
      end
    end
  end

  # ---- T-D2: the public synchronous run-one-prompt -> result entry ----------
  #
  # A role-selecting seam ({Skill::RoleSpawn}) builds a one-shot Subagent per
  # call and drives it DIRECTLY -- no model-facing {#call}/effect-handler
  # dispatch, no actor launch. {#run} is that entry: one prompt to a single
  # final {Tool::Result}, synchronously, over the same {#spawn_one_shot}
  # machinery {#perform} uses (so its records land in @last_* just the same).
  describe "the public #run entry (T-D2)" do
    it "runs one prompt to a single final result without the effect handler or the actor path" do
      tool = build_subagent(provider: mock(text_response("child answer")))
      result = tool.run("go")

      expect(result).to be_ok
      expect(result.content).to eq("child answer")
      expect(tool.last_child).not_to be_nil
      expect(tool.last_message.kind).to eq(:message)
    end

    it "honors the depth ceiling exactly as #perform does: refuses at 0, spawning nothing" do
      tool = build_subagent(provider: mock(text_response("unused")), max_depth: 0)
      before = store.size

      result = tool.run("go")

      expect(result).to be_error
      expect(result.content).to include("depth")
      expect(tool.last_spawn).to be_nil
      expect(store.size).to eq(before)
    end
  end

  # ---- Depth ceiling (escalation-trigger guard) -----------------------------

  describe "the spawn-depth ceiling" do
    it "refuses to spawn at depth 0, emitting no :spawn event and touching no Store" do
      tool = build_subagent(provider: mock(text_response("unused")), max_depth: 0)
      before = store.size

      result = tool.call({ "prompt" => "go" }, invocation)

      expect(result).to be_error
      expect(result.content).to include("depth")
      expect(store.size).to eq(before)
      expect(tool.last_spawn).to be_nil
    end

    # The ceiling must be TRANSITIVE (T19 panel, substantive): a Subagent
    # reachable in the child's union must not keep its constructing ceiling,
    # or recursion never terminates via the cap. Each spawn hands descendants
    # a decremented copy: depth 2 -> the child may spawn (copies at 1) -> the
    # grandchild may spawn (copies at 0) -> the great-grandchild is refused.
    it "decrements through descendants: depth 2 spawns child and grandchild, refuses the great-grandchild" do
      provider = mock(
        tool_response(["c1", "subagent", { "prompt" => "go deeper" }]),
        tool_response(["g1", "subagent", { "prompt" => "deeper still" }]),
        text_response("grandchild done"),
        text_response("child done")
      )
      deepest = build_subagent(provider:, policy: spawn_policy(only: []),
                               toolset: Lain::Toolset.new([EchoTool.new]), max_depth: 9)
      mid = build_subagent(provider:, policy: spawn_policy(only: []),
                           toolset: Lain::Toolset.new([EchoTool.new, deepest]), max_depth: 9)
      tool = build_subagent(provider:, policy: spawn_policy(only: []),
                            toolset: Lain::Toolset.new([EchoTool.new, mid]), max_depth: 2)

      result = tool.call({ "prompt" => "start" }, invocation)

      expect(result).to be_ok
      expect(result.content).to eq("child done")
      # Four model rounds: child x2 + grandchild x2. The great-grandchild was
      # refused BEFORE any model call, and the refusal reached the grandchild
      # as an is_error tool_result in its second request.
      expect(provider.call_count).to eq(4)
      refusal = provider.requests[2].messages.flat_map { |m| m["content"] }
                                             .find { |b| b.is_a?(Hash) && b["type"] == "tool_result" }
      expect(refusal["is_error"]).to be(true)
      expect(refusal["content"]).to include("depth")
    end

    # A tool's OWN tighter ceiling survives the copy: descending must never
    # RAISE a ceiling (that would be capability escalation), only lower it.
    it "never raises a descendant's own tighter ceiling" do
      provider = mock(
        tool_response(["c1", "subagent", { "prompt" => "go deeper" }]),
        text_response("child done")
      )
      never_spawns = build_subagent(provider:, policy: spawn_policy(only: []),
                                    toolset: Lain::Toolset.new([EchoTool.new]), max_depth: 0)
      tool = build_subagent(provider:, policy: spawn_policy(only: []),
                            toolset: Lain::Toolset.new([EchoTool.new, never_spawns]), max_depth: 5)

      result = tool.call({ "prompt" => "start" }, invocation)

      expect(result).to be_ok
      # Only the child's two rounds ran: its spawn attempt was refused even
      # though the spawner had depth to spare, because the inner tool said 0.
      expect(provider.call_count).to eq(2)
      refusal = provider.requests[1].messages.flat_map { |m| m["content"] }
                                             .find { |b| b.is_a?(Hash) && b["type"] == "tool_result" }
      expect(refusal["is_error"]).to be(true)
      expect(refusal["content"]).to include("depth")
    end

    # The exe shape -- a union holding no subagent -- passes through untouched:
    # nothing to replace, same names rendered.
    it "leaves a subagent-free union (the exe shape) unchanged" do
      provider = mock(text_response("done"))
      tool = build_subagent(provider:, policy: spawn_policy(posture: :handler_union), max_depth: 2)
      tool.call({ "prompt" => "go" }, invocation)

      expect(provider.last_request.tools.map { |t| t["name"] }).to eq(with_asker(union.names))
    end
  end

  # ---- T7: children get a real Session --------------------------------------
  #
  # Before this card, every spawned child ran under Session::Null
  # (spawn_agent's `session: Session::Null.instance`), so EditFile's
  # read-before-write contract -- its `requires` block calls
  # `session_of(invocation).read?(input.path)` -- could never be satisfied:
  # Session::Null#read? is unconditionally false. A write-capable child was
  # structurally unable to ever pass its own contract.
  describe "children get a real Session (T7)" do
    around do |example|
      Dir.mktmpdir do |dir|
        @tmpdir = dir
        example.run
      end
    end

    attr_reader :tmpdir

    def write(name, content)
      path = File.join(tmpdir, name)
      File.write(path, content)
      path
    end

    def tool_result_blocks(timeline)
      timeline.to_a.select { |turn| turn.role == "user" && turn.content.any? { |b| b["type"] == "tool_result" } }
                   .flat_map(&:content)
                   .select { |b| b["type"] == "tool_result" }
    end

    def read_edit_toolset
      Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::EditFile.new])
    end

    it "lets a write-capable child satisfy read-before-write" do
      path = write("hello.txt", "hello world")
      provider = mock(
        tool_response(["r1", "read_file", { "path" => path }]),
        tool_response(["e1", "edit_file", { "path" => path, "old_string" => "hello", "new_string" => "goodbye" }]),
        text_response("edited")
      )
      tool = build_subagent(provider:, toolset: read_edit_toolset, policy: spawn_policy(only: %i[read_file edit_file]))

      result = tool.call({ "prompt" => "read then edit" }, invocation)

      expect(result).to be_ok
      expect(tool_result_blocks(tool.last_child)).to all(include("is_error" => false))
      expect(File.read(path)).to eq("goodbye world")
    end

    it "does not hand a child the parent's read-set: the child's session starts empty" do
      path = write("hello.txt", "hello world")
      parent_session = Lain::Session.new.record_read(path)
      provider = mock(
        tool_response(["e1", "edit_file", { "path" => path, "old_string" => "hello", "new_string" => "goodbye" }]),
        text_response("gave up")
      )
      tool = build_subagent(provider:, toolset: read_edit_toolset, policy: spawn_policy(only: %i[read_file edit_file]))

      result = tool.call({ "prompt" => "edit blind" }, Lain::Tool::Invocation.new(context: parent_session))

      expect(result).to be_ok
      results = tool_result_blocks(tool.last_child)
      expect(results).not_to be_empty
      expect(results.first["is_error"]).to be(true)
      expect(File.read(path)).to eq("hello world")
    end

    it "gives sibling children their own Session: a second spawn does not inherit the first's read-set" do
      path = write("hello.txt", "hello world")
      provider = mock(
        tool_response(["r1", "read_file", { "path" => path }]),
        tool_response(["e1", "edit_file", { "path" => path, "old_string" => "hello", "new_string" => "goodbye" }]),
        text_response("first done"),
        tool_response(["e2", "edit_file", { "path" => path, "old_string" => "goodbye", "new_string" => "farewell" }]),
        text_response("second done")
      )
      tool = build_subagent(provider:, toolset: read_edit_toolset, policy: spawn_policy(only: %i[read_file edit_file]))

      first = tool.call({ "prompt" => "read then edit" }, invocation)
      expect(first).to be_ok
      expect(File.read(path)).to eq("goodbye world")

      second = tool.call({ "prompt" => "edit blind" }, invocation)
      expect(second).to be_ok
      second_results = tool_result_blocks(tool.last_child)
      expect(second_results.first["is_error"]).to be(true)
      expect(File.read(path)).to eq("goodbye world")
    end
  end

  # ---- T13 scope expansion: the observer reaches Lineage from the outside ----

  # The live session scribe attaches at the TOOL's constructor (the only seam
  # the exe wires), so Subagent must forward an `observer:` to the Lineage it
  # builds -- an observer nobody can wire from the exe is silent record loss
  # one level up.
  describe "the injectable observer (T13)" do
    it "sees the :spawn and :message events a spawn writes, with @log still receiving them" do
      seen = []
      log = Lain::Tools::Subagent::Log.new
      tool = described_class.new(
        provider: mock(text_response("did the thing")), context_factory: -> { child_context },
        toolset: union, policy: spawn_policy, parent:,
        log:, observer: seen.method(:push)
      )

      result = tool.call({ "prompt" => "go" }, invocation)

      expect(result).to be_ok
      expect(seen).to eq([tool.last_spawn, tool.last_message])
      expect(log.to_a).to eq([tool.last_spawn, tool.last_message])
    end

    it "defaults to no observer, every existing path byte-identical" do
      tool = build_subagent(provider: mock(text_response("done")))
      expect(tool.call({ "prompt" => "go" }, invocation)).to be_ok
    end
  end

  # ---- T10: a child of its own may ask the human ----------------------------
  #
  # The capability policy this chunk reverses. A subagent used to be denied
  # `ask_human` deliberately ({CLI::Wiring::ToolsetBuild}'s layering comment);
  # it now holds one of its OWN -- never the parent's, whose questions would be
  # attributed to the parent's chain and whose promise the parent's
  # {AskHuman::Outstanding} holds -- enrolled per spawn on the run's ONE
  # {CLI::Wiring::Askers}. That is what makes several question sets pending at
  # once, which is the case the inbox has always rendered for and the reply
  # path could not serve until the directory routed by name.
  #
  # Driven through the REAL arrival seam rather than through a directory alone.
  # A plain {AskHuman} writes Q to the Store and announces to nobody, and
  # {Event::Projection#pending} reads the Store -- so every other claim in this
  # block passes for a child whose questions never reach the TTY or the
  # desktop. The queue and the notifier are what say they do.
  describe "asking the human from inside a child (T10)" do
    let(:notified) { [] }
    let(:notifier) { instance_double(Lain::Notify) }
    let(:askers) { Lain::CLI::Wiring::Askers.new(notifier:, observer: Lain::Event::ChainWriter::Null.new) }

    # The chat the human is having, holding its own asker on the SAME seam --
    # so "parent and child are pending at once" is a claim about two real
    # askers and one queue, not about one asker asked twice.
    let(:parent_asker) { askers.enrol(parent, agent: "lain").asker }

    before { allow(notifier).to receive(:question) { |agent:, text:| notified << [agent, text] } }

    def asking_seam(provider)
      Lain::Tools::Subagent::Seam.new(provider:, context_factory: -> { child_context }, parent:, askers:)
    end

    def asking_subagent(provider, toolset: union, max_depth: 1, name: "subagent",
                        policy: spawn_policy(only: []), **over)
      described_class.new(seam: asking_seam(provider), toolset:, policy:, max_depth:, name:, **over)
    end

    def asks(question = "which db?") = tool_response(["c1", "ask_human", { "question" => question }])

    # Pumps the reactor until the caller's condition holds. A condition that
    # never comes true is a FAILING example, never a suite that hangs with
    # nothing to read (the human_replies_spec idiom).
    def pumped_until(task, timeout: 3)
      deadline = Async::Clock.now + timeout
      task.sleep(0.02) until yield || Async::Clock.now > deadline
      raise "the condition never held within #{timeout}s" unless yield
    end

    def arrival(task)
      pumped_until(task) { !askers.questions.empty? }
      askers.questions.dequeue
    end

    # Runs a spawn that PARKS on the human, and stops its fiber on every exit.
    #
    # The `ensure` is the whole reason these examples can FAIL. A dispatch that
    # asks a question does not return until the set is answered, so an
    # expectation that does not hold -- or the timeout above -- raises out of
    # the `Sync` while the child's fiber is still parked on `Promise#await`,
    # and a raise out of a Sync with a parked child NEVER RETURNS. The process
    # wedges, and a killed run prints "1 example, 0 failures" with no progress
    # character: a green line meaning nothing was measured, in the exact shape
    # a dead `parallel_rspec` worker takes. Stopping the task first is what
    # turns a silent child into a failing example instead of a hang, and it is
    # why every parked example below goes through this method or copies it.
    def spawning(task, tool)
      run = task.async { yield_result(tool) }
      yield run
    ensure
      run.stop
    end

    # The dispatch itself, on the child's fiber. `@dispatched` rather than a
    # block-local so `spawning`'s caller can read the result after the fiber
    # has been stopped as well as after it has finished.
    def yield_result(tool) = @dispatched = tool.call({ "prompt" => "go" }, invocation)

    attr_reader :dispatched

    # An actor parks the same way a one-shot dispatch does, so it is stopped on
    # every exit for `spawning`'s reason. {Actor#stop} is idempotent, so the
    # examples that stop it themselves are unaffected by this.
    def launching(tool, prompt: "go")
      actor = tool.launch_actor(prompt)
      yield actor
    ensure
      actor&.stop
    end

    def actor_tool
      asking_subagent(mock(asks, text_response("done")), mode: :actor, log: Lain::Tools::Subagent::Log.new)
    end

    def unroutable!(digest)
      expect { askers.directory.reply("too late", digest) }
        .to raise_error(Lain::Tools::AskHuman::NoPendingQuestion, /cannot be answered/)
    end

    # {Directory#size} counts NAMES, so a registration that never opened one is
    # invisible to it -- and an enrolment stranded by a failed launch is
    # exactly that shape. This reaches for the count the public surface does
    # not publish, because the alternative is an assertion that cannot fail.
    def registrations = askers.directory.instance_variable_get(:@registrations).size

    # Ask, arrive, answer, settle -- the full round trip, with the fiber
    # guaranteed stopped whichever step gives out.
    def answered(tool, answer: "postgres")
      item = nil
      Sync do |task|
        spawning(task, tool) do |run|
          item = arrival(task)
          askers.directory.reply(answer, item.digest)
          run.wait
        end
      end
      [dispatched, item]
    end

    it "offers ask_human to a spawned child, though the union it attenuates from holds none" do
      provider = mock(text_response("done"))

      asking_subagent(provider).call({ "prompt" => "go" }, invocation)

      expect(union.names).not_to include("ask_human")
      expect(provider.last_request.tools.map { |tool| tool["name"] }).to include("ask_human")
    end

    # THE acceptance criterion of this card: announcement lives in
    # {AskHuman::Notifying}, so a child wired to a bare asker satisfies every
    # other example here while its questions reach nobody.
    it "lands a child's question on the arrival queue a parent's goes to, and tells the desktop" do
      tool = asking_subagent(mock(asks, text_response("done")), name: "researcher")

      result, item = answered(tool)

      expect(result).to be_ok
      expect(result.content).to eq("done")
      expect(item.question.to_s).to eq("which db?")
      expect(notified).to eq([["researcher", "which db?"]])
    end

    # Who the human is TOLD is asking, at both surfaces that render a sender.
    #
    # The identifier is the asker's NAME, not its chain correlation.
    # `ChainWriter.correlation_of` is a chain's ROOT digest and an `:inherit`
    # child is `parent.fork`, so parent and child share a root permanently --
    # and `:inherit` is the DEFAULT posture for a `@role` spawn
    # (`middleware/skill_dispatch.rb`), which makes that the COMMON case
    # rather than a corner of one. Both postures are driven for exactly that
    # reason: the point of naming the asker is that who-is-asking stops
    # depending on which prefix strategy a spawn happened to use.
    describe "who the human is told is asking" do
      # A parent and a child holding a question each, at the same time, over
      # one queue -- the situation this whole card exists to create.
      def pending_pair(prefix)
        tool = asking_subagent(mock(asks("deploy now?"), text_response("done")),
                               policy: spawn_policy(only: [], prefix:), announces_as: "researcher")
        Sync { |task| spawning(task, tool) { |run| both_asked(task, run) } }
        @pair
      end

      # The parent asks beside the child, both are listed, then both are
      # answered so the dispatch can settle rather than the fiber being cut.
      def both_asked(task, run)
        parent_asker.ask("which db?")
        pumped_until(task) { askers.questions.size == 2 }
        @pair = answered_pair
        run.wait
      end

      # Both listed items, taken off the queue and answered -- so the child's
      # dispatch settles on its own rather than being cut by `spawning`'s
      # ensure, which would leave the example proving less than it says.
      def answered_pair
        [askers.questions.dequeue, askers.questions.dequeue]
          .each { |item| askers.directory.reply("ok", item.digest) }
      end

      # The sender column, as a surface prints it: both clamp, and two names
      # that differ only PAST the clamp collide on screen even though the
      # values do not.
      def senders(lines) = lines.map { |line| line.split("  ").first }

      # Surface 1 -- the TTY. `Frontend::TTY::Inbox` renders `item.from` in
      # both places it names an asker: the arrival note (`#arrival`, through
      # `HumanReplies#render_arrival`) and the `/inbox` drain (`#line_for`).
      # Clamped here to the width the three surfaces share.
      def tty_senders(items)
        items.map { |item| item.from.to_s[0, Lain::CLI::Wiring::Askers::NAME_WIDTH] }
      end

      # Surface 2 -- the nvim inbox buffer. It does NOT consume the arrival:
      # it folds the RECORD stream ({Telemetry::Message}, the shape its own
      # spec drives) and builds its own row, so what it renders is
      # `event.from` and never the name the arrival carries.
      def nvim_senders(items)
        view = Lain::Frontend::Neovim::InboxView.new(store:, clock: -> { Time.at(0) })
        senders(items.map { |item| Lain::Telemetry::Message.from_event(store.fetch(item.digest)) }
                     .map { |record| view.update(record) }.last)
      end

      %i[fresh inherit].each do |prefix|
        it "names the child apart from its parent at the TTY drain, on a #{prefix} spawn" do
          expect(tty_senders(pending_pair(prefix))).to contain_exactly("lain", "researcher")
        end
      end

      # The old identifier, named so a regression to it cannot pass: this is
      # the exact value that made an `:inherit` child indistinguishable.
      it "uses the asker's name and not the correlation an :inherit child shares with its parent" do
        items = pending_pair(:inherit)

        expect(items.map(&:from)).not_to include(Lain::Event::ChainWriter.correlation_of(parent))
      end

      it "names the child apart from its parent in the nvim inbox, on a fresh spawn" do
        expect(nvim_senders(pending_pair(:fresh)).uniq.size).to eq(2)
      end

      # PINNED PENDING, and it is the half the arrival fix does NOT reach.
      # `HumanReplies::InboxItem.asked` now prefers the asker's name, which
      # closes the TTY; the nvim view never sees an InboxItem, so it still
      # renders the shared root digest and the two rows still collide. Closing
      # it means the NAME riding the record -- the Q event's body, or
      # {Telemetry::Message} -- neither of which is in this card's files.
      # Written as the behaviour wanted, so it goes green when that lands.
      it "names the child apart from its parent in the nvim inbox, on an inherit spawn" do
        pending("the nvim view folds the record stream, where the asker's name does not ride: it renders event.from")

        expect(nvim_senders(pending_pair(:inherit)).uniq.size).to eq(2)
      end
    end

    it "carries the human's answer back into the child's own conversation" do
      tool = asking_subagent(mock(asks, text_response("done")))

      answered(tool, answer: "postgres, it is already provisioned")

      delivered = tool.last_child.to_a.flat_map(&:content).select { |block| block["type"] == "tool_result" }
      expect(delivered.map { |block| block["content"] }).to eq(["postgres, it is already provisioned"])
    end

    it "keeps the parent and the child pending at once, and the inbox projection lists both" do
      tool = asking_subagent(mock(asks("deploy now?"), text_response("done")))

      Sync do |task|
        spawning(task, tool) do |run|
          parent_asker.ask("which db?")
          pumped_until(task) { askers.questions.size == 2 }
          items = [askers.questions.dequeue, askers.questions.dequeue]

          expect(parent_asker).to be_pending
          expect(items.map(&:from).uniq.size).to eq(2)
          expect(Lain::Event::Projection.new(items.map { |item| store.fetch(item.digest) })
                                        .pending("human").to_a.size).to eq(2)

          items.each { |item| askers.directory.reply("ok", item.digest) }
          run.wait
        end
      end
    end

    it "resolves each set through the asker that asked it, never through whoever asked last" do
      tool = asking_subagent(mock(asks("deploy now?"), text_response("done")))

      Sync do |task|
        spawning(task, tool) do |run|
          child_item = arrival(task)
          parent_set = parent_asker.ask("which db?")

          askers.directory.reply("postgres", parent_set.digest)

          expect(parent_asker.last_answer.body["answer"]).to eq("postgres")
          expect(dispatched).to be_nil

          askers.directory.reply("kubernetes", child_item.digest)
          run.wait
        end
      end

      expect(dispatched.content).to eq("done")
      delivered = tool.last_child.to_a.flat_map(&:content).select { |block| block["type"] == "tool_result" }
      expect(delivered.map { |block| block["content"] }).to eq(["kubernetes"])
    end

    # The union {ChildBuilder#child_union} hands a grandchild is the base one
    # again, so the capability rides the SEAM rather than the set -- which is
    # the whole reason a descended copy re-injects the seam verbatim.
    it "gives a grandchild an asker of its own" do
      provider = mock(tool_response(["c1", "subagent", { "prompt" => "deeper" }]),
                      text_response("grandchild done"), text_response("child done"))
      inner = asking_subagent(provider, max_depth: 9)
      outer = asking_subagent(provider, toolset: Lain::Toolset.new(union.to_a + [inner]), max_depth: 2)

      expect(outer.call({ "prompt" => "go" }, invocation)).to be_ok
      expect(provider.requests[1].tools.map { |tool| tool["name"] }).to include("ask_human")
    end

    # The grant passes through the SAME posture gate the rest of the child's
    # set does -- it is not handed out past the session.
    it "keeps the child's asker whenever the session posture permits ask_human" do
      provider = mock(text_response("done"))
      seam = asking_seam(provider).with(permits: Lain::Mode::Posture::Permits::Only.new(%i[read_file ask_human]))
      tool = described_class.new(seam:, toolset: union, policy: spawn_policy(only: []), max_depth: 1)

      tool.call({ "prompt" => "go" }, invocation)

      expect(provider.last_request.tools.map { |tool| tool["name"] }).to eq(%w[ask_human read_file])
    end

    # The second gate {ChildBuilder#permitted} stands: a posture that does not
    # permit ask_human MUTES the child rather than silently handing it an
    # asker the session itself may not use.
    it "withholds the asker from a child whose session posture does not permit it" do
      provider = mock(text_response("done"))
      seam = asking_seam(provider).with(permits: Lain::Mode::Posture::Permits::Only.new(%i[read_file]))
      tool = described_class.new(seam:, toolset: union, policy: spawn_policy(only: []), max_depth: 1)

      tool.call({ "prompt" => "go" }, invocation)

      expect(provider.last_request.tools.map { |tool| tool["name"] }).to eq(%w[read_file])
    end

    # The muted path must not leave the PARENT's asker standing. Under
    # `handler_union` the union is what the child is SHOWN and what
    # {Effect::Handler::Live} dispatches against, so an `ask_human` surviving
    # there is the parent's own -- reachable by the very child the posture
    # just muted, and resolving into the parent's {AskHuman::Outstanding}.
    it "strips the parent's asker from the dispatch union too when the posture mutes it" do
      provider = mock(text_response("done"))
      poisoned = Lain::Toolset.new(union.to_a + [Lain::Tools::AskHuman.new(parent:)])
      seam = asking_seam(provider).with(permits: Lain::Mode::Posture::Permits::Only.new(%i[read_file echo]))
      tool = described_class.new(seam:, toolset: poisoned, max_depth: 1,
                                 policy: spawn_policy(only: [], posture: :handler_union))

      tool.call({ "prompt" => "go" }, invocation)

      expect(provider.last_request.tools.map { |tool| tool["name"] }).to eq(%w[echo read_file])
    end

    # Retention runs from `register` to `deregister` and NOTHING else releases
    # it, so the release has to ride the lifetime that owns the child. For a
    # one-shot that lifetime IS the dispatch.
    it "releases a one-shot child's registration when its dispatch ends" do
      tool = asking_subagent(mock(asks, text_response("done")))

      result, item = answered(tool)

      expect(result).to be_ok
      unroutable!(item.digest)
    end

    # And for an actor it is the lease that reaps the fiber. Both directions
    # are pinned: still routable while the actor runs (a second answer is
    # refused as ALREADY ANSWERED, by the registration's own tombstone), and
    # no longer routable once it has stopped (refused as unknown).
    it "releases a child's registration when its actor stops, so a late answer is refused not misrouted" do
      Sync do |task|
        launching(actor_tool) do |actor|
          item = arrival(task)
          askers.directory.reply("postgres", item.digest)
          actor.settle

          expect { askers.directory.reply("again", item.digest) }.to raise_error(Lain::Promise::AlreadyResolved)

          actor.stop

          unroutable!(item.digest)
          expect(parent_asker.last_answer).to be_nil
        end
      end
    end

    # The whole point of enrolling INSIDE the launch is that a launch which
    # never produced an actor must not leave an asker nothing will release:
    # the Actor reference goes with the raise, so nothing else could ever
    # `deregister` it. Driven through the seam's observer, which
    # {Event::ChainWriter#put} documents as raising OUT of the write.
    it "releases the child's registration when the launch itself raises" do
      seam = asking_seam(mock(text_response("unused"))).with(observer: ->(_e) { raise "the record is on fire" })
      tool = described_class.new(seam:, toolset: union, policy: spawn_policy(only: []),
                                 max_depth: 1, mode: :actor, log: Lain::Tools::Subagent::Log.new)

      Sync { expect { tool.launch_actor("go") }.to raise_error(/the record is on fire/) }

      expect(registrations).to eq(0)
    end

    # The arrival note names what the child IS, not what the model calls the
    # tool. `research_subagent` is the one child path that ships today, and its
    # tool is named "subagent" because that is the model-facing name -- the
    # human must be told "researcher".
    it "announces under the spawn's own name, which need not be the model-facing tool name" do
      tool = asking_subagent(mock(asks, text_response("done")), name: "subagent", announces_as: "researcher")

      answered(tool)

      expect(notified).to eq([["researcher", "which db?"]])
    end

    it "falls back to the tool's own name when a spawn has no separate one" do
      tool = asking_subagent(mock(asks, text_response("done")), name: "subagent")

      answered(tool)

      expect(notified).to eq([["subagent", "which db?"]])
    end

    # ---- The `ensure` on Actor#stop, pinned (S2) ---------------------------
    #
    # That `ensure` is the entire reason this card touched `actor.rb`, and a
    # release written among the method's own lines would be skipped by BOTH of
    # its early exits -- silently, with every other example in this block
    # still green. Those two exits are also the shapes {Supervisor#stop}'s
    # rescue-less `each { farewell }` meets in a real teardown, so what is
    # pinned here is both halves: the release happens, and #stop stays
    # incapable of stranding the rows behind it.
    describe "the release on Actor#stop" do
      # A registered asker with a question outstanding, wearing an Actor that
      # has NOT been launched: the state a supervisor row is in when its
      # launch block raised, and the one `raise NotLaunched` returns from.
      def never_launched
        enrolled = askers.enrol(parent, agent: "orphan")
        digest = enrolled.asker.ask("who is stuck?").digest
        actor = Lain::Tools::Subagent::Actor.new(
          agent: instance_double(Lain::Agent), parent:, registration: enrolled.registration,
          lineage: Lain::Tools::Subagent::Lineage.new(policy: spawn_policy)
        )
        [actor, digest]
      end

      it "releases the registration of an actor that was never launched, and still refuses loudly" do
        Sync do
          actor, digest = never_launched

          expect { actor.stop }.to raise_error(Lain::Tools::Subagent::Actor::NotLaunched)

          unroutable!(digest)
        end
      end

      it "releases when stopped with the child's question still outstanding, and re-answers the same farewell" do
        Sync do |task|
          launching(actor_tool) do |actor|
            item = arrival(task)

            first = actor.stop
            second = actor.stop

            expect(second).to be(first)
            unroutable!(item.digest)
          end
        end
      end
    end
  end

  # ---- B9: the staggered sibling fan-out (CE-5) -----------------------------
  #
  # The plumb this card adds: a REAL fan-out of sibling-template children
  # through {Stagger}, each child's {Agent} forwarding `on_stream_started` down
  # its own provider round trip. Sibling 1 dispatches alone; the provider's
  # first-token signal ({Provider::Mock}'s here, gated on `request.stream` just
  # as the live backends gate it) opens the gate and the rest release -- one
  # writable template prefix, N-1 byte-identical reuses. The stagger releases
  # land in the journal. The stagger POLICY in isolation is proven in
  # spec/lain/tools/subagent/stagger_spec.rb; these prove the wiring reaches it
  # THROUGH the provider signal.
  describe "the staggered sibling fan-out (B9)" do
    let(:template) { "You are one of a set of sibling workers over one shared brief. " * 20 }

    def sibling_template_policy(template)
      Lain::Tool::SpawnPolicy.new(
        prefix: Lain::Tool::SpawnPolicy::PrefixStrategy::SiblingTemplate.new(template:),
        posture: :handler_union, only: %i[read_file]
      )
    end

    it "spawns each prompt as a sibling child, returning one final result per prompt in order" do
      provider = mock(text_response("a"), text_response("b"), text_response("c"))
      tool = build_subagent(provider:, policy: sibling_template_policy(template))

      results = tool.fan_out(%w[alpha beta gamma])

      expect(results.map(&:content)).to eq(%w[a b c])
      expect(results).to all(be_ok)
    end

    it "returns [] for an empty fan-out, spawning nothing" do
      tool = build_subagent(provider: mock(text_response("unused")))
      before = store.size

      expect(tool.fan_out([])).to eq([])
      expect(store.size).to eq(before)
    end

    # AC1 (Gherkin): sibling 1 begins streaming -> the rest release, journaled.
    it "releases the rest on sibling 1's stream-start, journaling the stagger with reason :stream_started" do
      journal = Lain::Channel.new
      provider = mock(text_response("a"), text_response("b"), text_response("c"))
      tool = build_subagent(provider:, policy: sibling_template_policy(template), journal:)

      tool.fan_out(%w[alpha beta gamma])

      events = journal.drain
      dispatched = events.grep(Lain::Tools::Subagent::Stagger::Dispatched)
      released = events.grep(Lain::Tools::Subagent::Stagger::Released)
      expect(dispatched.map(&:index)).to contain_exactly(0, 1, 2)
      expect(released.map(&:reason)).to eq([:stream_started])
    end

    # AC2 (Gherkin): the first never streams -> the rest release on the degrade
    # path, journaled. A non-streaming child context is the honest analogue of a
    # provider that never signals: Mock gates its signal on `request.stream`, so
    # the whole fan-out falls through to Stagger's :degraded release rather than
    # hanging.
    it "degrades safely, releasing the rest journaled :degraded, when the first child never streams" do
      journal = Lain::Channel.new
      provider = mock(text_response("a"), text_response("b"))
      tool = described_class.new(
        provider:, context_factory: -> { Lain::Context.new(model: "child-model", max_tokens: 256, stream: false) },
        toolset: union, policy: sibling_template_policy(template), parent:, journal:
      )

      results = nil
      expect { Timeout.timeout(2) { results = tool.fan_out(%w[alpha beta]) } }.not_to raise_error

      expect(results.map(&:content)).to eq(%w[a b])
      released = journal.drain.grep(Lain::Tools::Subagent::Stagger::Released)
      expect(released.map(&:reason)).to eq([:degraded])
    end
  end

  # ---- W3: the OM-6 Supervisor unrefuses the model-dispatched :actor ---------
  #
  # The T23 refusal reasoning stands for a BARE dispatch: Agent#ask's per-call
  # Sync owns any fiber a tool dispatch spawns, so a perform-launched actor
  # would park as ask's own child and wedge the loop. A running Supervisor is
  # the missing reactor above the Agent -- perform adopts the launch onto ITS
  # task, so the fiber outlives the ask and the dispatch returns the handle.
  describe "a model-dispatched :actor" do
    let(:actor_log) { Lain::Tools::Subagent::Log.new }

    def actor_mode_tool(*responses, supervisor:)
      described_class.new(
        provider: mock(*responses), context_factory: -> { child_context },
        toolset: union, policy: spawn_policy, parent:,
        mode: :actor, log: actor_log, supervisor:
      )
    end

    # `supervisor.stop` is in an `ensure`, and that is not tidiness: the reactor
    # task it stops is a CHILD of this `Sync`, so a failed expectation that skips
    # the stop leaves `Sync` waiting on a task that never finishes -- the example
    # hangs instead of reporting, and with it every example after it in the file.
    # A mutation campaign found this the expensive way.
    it "launches under a running Supervisor: the spawn lands, the handle returns, no refusal" do
      supervisor = Lain::Supervisor.new
      Sync do |task|
        supervisor.run(task)
        tool = actor_mode_tool(text_response("actor ready"), supervisor:)

        result = tool.call({ "prompt" => "go" }, invocation)

        expect(result).to be_ok
        spawn = actor_log.to_a.find { |event| event.kind == :spawn }
        expect(spawn).not_to be_nil
        expect(result.content).to include(spawn.digest)
        expect(supervisor.map(&:address)).to eq([spawn.digest])
        expect(supervisor.map(&:role)).to eq(["subagent"])
      ensure
        supervisor.stop
      end
    end

    it "does not wedge the parent's ask: the loop settles while the actor persists" do
      supervisor = Lain::Supervisor.new
      Sync do |task|
        supervisor.run(task)
        tool = actor_mode_tool(text_response("actor ready"), supervisor:)
        parent_agent = Lain::Agent.new(
          provider: mock(tool_response(["a1", "subagent", { "prompt" => "go" }]), text_response("parent continues")),
          toolset: Lain::Toolset.new([tool]),
          context: Lain::Context.new(model: "parent", max_tokens: 256),
          timeline: Lain::Timeline.empty(store:)
        )

        response = parent_agent.ask("spawn an actor")

        expect(response.text).to eq("parent continues")
        actor = supervisor.first.actor
        expect(actor.settle).not_to be_dead
      ensure
        supervisor.stop
      end
    end

    # AC: no supervisor still refuses loudly -- today's message, no event, no
    # Store touch. The default is Supervisor::Null, so an unwired tool behaves
    # byte-identically to the pre-W3 refusal.
    it "still refuses with today's message when no supervisor is wired" do
      tool = described_class.new(
        provider: mock(text_response("unused")), context_factory: -> { child_context },
        toolset: union, policy: spawn_policy, parent:, mode: :actor, log: actor_log
      )
      before = store.size

      result = tool.call({ "prompt" => "go" }, invocation)

      expect(result).to be_error
      expect(result.content).to match(/OM-6|supervisor|launch_actor/)
      expect(actor_log.to_a).to be_empty
      expect(store.size).to eq(before)
    end

    it "refuses the same way under a supervisor that is not running" do
      stopped = Lain::Supervisor.new
      tool = actor_mode_tool(text_response("unused"), supervisor: stopped)

      result = tool.call({ "prompt" => "go" }, invocation)

      expect(result).to be_error
      expect(result.content).to include("supervisor")
    end
  end

  # ---- T23: the child-spawn collaborators travel as ONE Seam value -----------
  #
  # The six a child spawn is always built over -- provider, child-Context
  # factory, live parent handle, journal, supervisor, lineage observer -- were
  # loose keywords on three signatures, bundled into a Hash at the one place
  # ({CLI::Wiring::ToolsetBuild#child_seam_kwargs}) that already knew they were
  # one thing. Naming the value is what makes "over the same seams" checkable,
  # and what makes a seventh member a one-place change.
  #
  # Every OTHER example in this file constructs with the loose keywords, so this
  # block's green plus theirs is the additive claim: both styles are valid.
  describe "the spawn Seam (T23)" do
    let(:seam) do
      Lain::Tools::Subagent::Seam.new(provider: mock(text_response("seamed")),
                                      context_factory: -> { child_context }, parent:)
    end

    it "spawns over an injected seam, with no loose collaborator keywords" do
      tool = described_class.new(seam:, toolset: union, policy: spawn_policy, max_depth: 3)

      result = tool.call({ "prompt" => "go" }, invocation)

      expect(result).to be_ok
      expect(result.content).to eq("seamed")
      expect(tool.seam).to be(seam)
    end

    # The last three are Null-defaulted, so a caller who wires none of them gets
    # byte-identically what the pre-seam constructor's own defaults gave. All
    # three are the SAME object every time, which is what the next example needs.
    it "defaults journal, supervisor and observer to their Null objects" do
      expect(seam.journal).to be(Lain::Channel::Null.instance)
      expect(seam.supervisor).to be(Lain::Supervisor::Null)
      expect(seam.observer).to be(Lain::Tools::Subagent::NO_OBSERVER)
      expect(Lain::Tools::Subagent::NO_OBSERVER).to be_frozen
    end

    # T10's member. Its Null is a module rather than an instance for the same
    # reason the three above are singletons: a fresh object per default would
    # make two otherwise identical seams compare unequal.
    it "defaults the ask-the-human seam to the one wired to nothing" do
      expect(seam.askers).to be(Lain::Tools::Subagent::NoAskers)
    end

    # A value object whose `==` depends on WHICH member the caller let default is
    # a trap: `observer:` used to default to a FRESH ChainWriter::Null, so two
    # seams over identical collaborators compared unequal while their two
    # singleton neighbours compared equal.
    it "equates two seams built from the same collaborators, defaults included" do
      members = { provider: :p, context_factory: :cf, parent: :pa }

      expect(Lain::Tools::Subagent::Seam.new(**members))
        .to eq(Lain::Tools::Subagent::Seam.new(**members))
    end

    it "requires the three that have no Null: provider, context factory, and parent" do
      expect { Lain::Tools::Subagent::Seam.new(provider: mock, context_factory: -> { child_context }) }
        .to raise_error(ArgumentError, /parent/)
    end

    # Both styles are valid; holding both at once is the one thing that cannot
    # be honored, so it raises at construction rather than silently preferring
    # one and discarding the other.
    it "refuses a seam and its loose members together, naming the member" do
      expect { described_class.new(seam:, provider: mock, toolset: union, policy: spawn_policy) }
        .to raise_error(ArgumentError, "pass seam: or its members [:provider], not both")
    end

    # The loose path must stay as loud as Ruby's own keyword checking was: a
    # misspelled collaborator is a silent Null default if the splat swallows it.
    it "refuses a loose keyword that is not a seam member" do
      expect do
        described_class.new(provider: mock, context_factory: -> { child_context }, parent:,
                            observers: [], toolset: union, policy: spawn_policy)
      end.to raise_error(ArgumentError, /unknown keyword: :observers/)
    end

    # A typo BESIDE a seam is still a typo. Diagnosing it as a both-at-once
    # conflict sends the reader hunting for a member they never passed, so the
    # seam path says exactly what Data's own `new` says on the loose path.
    it "calls a misspelled keyword beside a seam a typo, not a conflict" do
      expect { described_class.new(seam:, toolset: union, policy: spawn_policy, max_dept: 3) }
        .to raise_error(ArgumentError, "unknown keyword: :max_dept")
    end

    it "names every stray keyword when several arrive beside a seam" do
      expect { described_class.new(seam:, toolset: union, policy: spawn_policy, max_dept: 3, nam: "x") }
        .to raise_error(ArgumentError, "unknown keywords: :max_dept, :nam")
    end

    # A descended copy re-injects the seam verbatim EXCEPT the parent handle: a
    # grandchild's lineage must name the CHILD's head, while the observer and
    # supervisor must stay the same objects or a nested spawn's record vanishes
    # one level up.
    it "descends the seam onto the child, rebinding only the parent" do
      wired = seam.with(observer: ->(_event) {}, supervisor: Lain::Supervisor.new, journal: Lain::Channel.new)
      tool = described_class.new(seam: wired, toolset: union, policy: spawn_policy, max_depth: 3)
      child_handle = -> { parent }

      copy = tool.descend(parent: child_handle, ceiling: 1)

      expect(copy.seam.parent).to be(child_handle)
      expect(copy.seam.to_h.except(:parent)).to eq(wired.to_h.except(:parent))
    end

    # The union a child attenuates FROM, published. It was reachable only by a
    # two-deep `instance_variable_get(:@builder).instance_variable_get(:@toolset)`
    # (toolset_build_spec's own reach-through), which pins the extraction's
    # private shape instead of the capability floor the bench wants to read.
    it "publishes the union a child attenuates from" do
      tool = described_class.new(seam:, toolset: union, policy: spawn_policy)

      expect(tool.attenuates_from).to be(union)
    end
  end
end
