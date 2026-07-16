# frozen_string_literal: true

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
      expect(rendered).to eq(%w[read_file])
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
      expect(rendered).to eq(union.names)

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

  # ---- Depth ceiling (escalation-trigger guard) -----------------------------

  describe "the spawn-depth ceiling" do
    it "refuses to spawn at depth 0, emitting no :spawn event and touching no Store" do
      tool = build_subagent(provider: mock(text_response("unused")), max_depth: 0)
      before = store.size

      result = tool.call({ "prompt" => "go" }, invocation)

      expect(result).to be_error
      expect(result.content).to match(/depth/)
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
      expect(refusal["content"]).to match(/depth/)
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
      expect(refusal["content"]).to match(/depth/)
    end

    # The exe shape -- a union holding no subagent -- passes through untouched:
    # nothing to replace, same names rendered.
    it "leaves a subagent-free union (the exe shape) unchanged" do
      provider = mock(text_response("done"))
      tool = build_subagent(provider:, policy: spawn_policy(posture: :handler_union), max_depth: 2)
      tool.call({ "prompt" => "go" }, invocation)

      expect(provider.last_request.tools.map { |t| t["name"] }).to eq(union.names)
    end
  end
end
