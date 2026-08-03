# frozen_string_literal: true

# CE-4 compares :schema and :handler_union on cache economics. That comparison
# is honest only if the two postures agree on everything but the refusal
# shape -- so this file runs ONE scripted child conversation under each
# posture and pins where they must agree (allowed-call delivery, rendered
# schemas) against the one place they are DESIGNED to diverge (a disallowed
# call). The existing single-posture refusal pin (subagent_spec.rb:161-180)
# stays where it is; this file is the two-posture comparison it does not make.
RSpec.describe "Subagent posture equivalence" do
  let(:store) { Lain::Store.new }
  let(:parent) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                  .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
  end

  # echo is the allowed member of the only-set; read_file is deliberately
  # outside it, so a scripted call to read_file is the disallowed probe --
  # its execution never has to happen (both postures refuse before dispatch),
  # so no filesystem fixture is needed.
  let(:union) { Lain::Toolset.new([EchoTool.new, Lain::Tools::ReadFile.new]) }
  let(:child_context) { Lain::Context.new(model: "child-model", max_tokens: 256) }
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }

  def spawn_policy(posture:, only: %i[echo])
    Lain::Tool::SpawnPolicy.new(posture:, only:)
  end

  def build_subagent(provider:, posture:, journal: Lain::Channel::Null.instance)
    Lain::Tools::Subagent.new(
      provider:, context_factory: -> { child_context }, toolset: union,
      policy: spawn_policy(posture:), parent:, journal:,
      budget: Lain::Agent::Budget.new, max_depth: 3
    )
  end

  def mock(*responses)
    Lain::Provider::Mock.new(responses:)
  end

  def tool_result_blocks(timeline)
    timeline.to_a.select { |turn| turn.role == "user" && turn.content.any? { |b| b["type"] == "tool_result" } }
                 .flat_map(&:content)
                 .select { |b| b["type"] == "tool_result" }
  end

  # Two single-tool-use rounds, both naming the allowed tool, so the sequence
  # is entirely within the only-set -- the "agreement" half of the comparison.
  def allowed_calls
    [
      tool_response(["c1", "echo", { "text" => "alpha" }]),
      tool_response(["c2", "echo", { "text" => "beta" }]),
      text_response("done")
    ]
  end

  # One round naming a tool outside the only-set -- the "divergence" half.
  def disallowed_call
    [
      tool_response(["d1", "read_file", { "path" => "/nonexistent" }]),
      text_response("done")
    ]
  end

  it "delivers extensionally equal tool_result blocks across postures for allowed calls" do
    schema_tool = build_subagent(provider: mock(*allowed_calls), posture: :schema)
    schema_tool.call({ "prompt" => "go" }, invocation)

    union_tool = build_subagent(provider: mock(*allowed_calls), posture: :handler_union)
    union_tool.call({ "prompt" => "go" }, invocation)

    # Deliberately NOT asserted: the child's final text under Provider::Mock is
    # script-determined either way, so it carries no information about the
    # postures and would only couple this spec to an incidental value.
    expect(tool_result_blocks(schema_tool.last_child)).to eq(tool_result_blocks(union_tool.last_child))
  end

  it "diverges on a disallowed call in exactly the refusal shape" do
    schema_journal = Lain::Channel.new
    schema_tool = build_subagent(provider: mock(*disallowed_call), posture: :schema, journal: schema_journal)
    schema_tool.call({ "prompt" => "go" }, invocation)

    union_journal = Lain::Channel.new
    union_tool = build_subagent(provider: mock(*disallowed_call), posture: :handler_union, journal: union_journal)
    union_tool.call({ "prompt" => "go" }, invocation)

    schema_result = tool_result_blocks(schema_tool.last_child).first
    union_result = tool_result_blocks(union_tool.last_child).first

    # Both answer is_error -- the disallowed call fails under either posture...
    expect(schema_result["is_error"]).to be(true)
    expect(union_result["is_error"]).to be(true)

    # ...but the DESIGNED divergence is how each posture reaches that answer:
    # schema never rendered read_file, so Live's Toolset#fetch raises
    # UnknownTool and no refusal is journaled; handler_union rendered the
    # union (read_file visible) and RefusingHandler journals the refusal.
    expect(schema_journal.drain.map { |event| event.to_journal["type"] }).not_to include("refused")
    expect(union_journal.drain.map { |event| event.to_journal["type"] }).to include("refused")
  end

  it "renders schemas exactly as each posture declares" do
    schema_provider = mock(text_response("done"))
    build_subagent(provider: schema_provider, posture: :schema).call({ "prompt" => "go" }, invocation)

    union_provider = mock(text_response("done"))
    build_subagent(provider: union_provider, posture: :handler_union).call({ "prompt" => "go" }, invocation)

    # T10 grants every child an `ask_human` of its own, on TOP of whichever
    # set the posture declares -- so both blocks carry it, and what this
    # example is about (schema renders the allowed set, handler_union renders
    # the whole union) is the rest of each list.
    expect(schema_provider.last_request.tools.map { |t| t["name"] }).to eq(%w[ask_human echo])
    expect(union_provider.last_request.tools.map { |t| t["name"] }).to eq((union.names + %w[ask_human]).sort)
  end
end
