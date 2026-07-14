# frozen_string_literal: true

# ToolRunner turns an assistant turn's tool_use blocks into the tool_result
# blocks that answer them. These close the spec-less gap on the collaborator
# directly, rather than only through agent_spec.
RSpec.describe Lain::Agent::ToolRunner do
  # Answers every call with a result naming the id it saw, so order and
  # id-matching are observable in the returned blocks.
  def echoing_handler
    Lain::Effect::Handler::Mock.new do |effect, _context|
      Lain::Tool::Result.ok("ran #{effect.tool_use_id}")
    end
  end

  # Gate 2: all of a turn's tool_results assemble into ONE user message, in the
  # order the tool_use blocks appeared. ToolRunner produces exactly that ordered
  # list; the Agent commits it as a single user turn.
  it "answers every tool_use with an ordered tool_result (gate 2, one user turn)" do
    response = tool_response(
      ["tu_1", "echo", { "text" => "a" }],
      ["tu_2", "echo", { "text" => "b" }]
    )

    blocks = described_class.new(handler: echoing_handler).run(response, context: nil)

    expect(blocks.map { |block| block["type"] }).to eq(%w[tool_result tool_result])
    # Gate 4: each result carries the id of the tool_use that asked for it, order preserved.
    expect(blocks.map { |block| block["tool_use_id"] }).to eq(%w[tu_1 tu_2])
    expect(blocks.map { |block| block["content"] }).to eq(["ran tu_1", "ran tu_2"])
  end

  it "reports a failed tool as is_error rather than raising past the loop (gate 3)" do
    handler = Lain::Effect::Handler::Mock.new do |_effect, _context|
      Lain::Tool::Result.error("boom")
    end
    response = tool_response(["tu_1", "boom", {}])

    block = described_class.new(handler:).run(response, context: nil).first

    expect(block["is_error"]).to be(true)
    expect(block["content"]).to eq("boom")
  end

  # Gate 5: the Provider has already parsed `tool_use.input` into a Hash;
  # ToolRunner fetches it and hands it to the effect verbatim, performing no
  # String -> Hash re-parse of its own. So the effect sees a Hash, never a raw
  # JSON String -- the parsing responsibility stays with the Provider.
  it "passes the parsed Hash input through to the effect, never re-parsing (gate 5)" do
    seen_input = nil
    handler = Lain::Effect::Handler::Mock.new do |effect, _context|
      seen_input = effect.input
      Lain::Tool::Result.ok("ok")
    end
    input = { "text" => "hi" }
    response = tool_response(["tu_1", "echo", input])

    described_class.new(handler:).run(response, context: nil)

    expect(seen_input).to be_a(Hash)
    expect(seen_input).to eq(input)
  end

  it "threads the effect through its middleware phase, terminating in the handler" do
    seen = nil
    probe = Class.new(Lain::Middleware::Base) do
      define_method(:call) do |env, &downstream|
        seen = env
        downstream.call(env)
      end
    end.new
    stack = Lain::Middleware::Stack.new.use(probe)
    response = tool_response(["tu_1", "echo", { "text" => "a" }])

    described_class.new(handler: echoing_handler, middleware: stack).run(response, context: :ctx)

    expect(seen).to be_a(Lain::Middleware::Env)
    expect(seen.effect).to be_a(Lain::Effect::ToolCall)
    expect(seen[:context]).to eq(:ctx)
  end
end
