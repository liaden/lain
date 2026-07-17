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

  # I6: one user-turn delivery = the tool_result blocks PLUS the consumption
  # edges harvested from the toolset -- pinned here at the collaborator's own
  # boundary with consume-once fakes, so the contract does not rest on
  # agent_spec's end-to-end examples alone.
  describe "#delivery" do
    # The real Tools::AskHuman#take_answered_questions shape: hands its
    # digests over exactly once, empty ever after.
    def handover_tool(name, digests)
      fake = Struct.new(:name).new(name)
      queue = digests.dup
      fake.define_singleton_method(:take_answered_questions) do
        handed = queue.dup
        queue.clear
        handed
      end
      fake
    end

    def plain_tool(name) = Struct.new(:name).new(name)

    def runner(*tools)
      described_class.new(handler: echoing_handler, toolset: Lain::Toolset.new(tools))
    end

    it "pairs the tool_result blocks with the harvested digests as causal_parents" do
      subject = runner(plain_tool("echo"), handover_tool("ask_human", ["blake3:q1"]))

      delivery = subject.delivery(tool_response(["tu_1", "ask_human", { "question" => "q?" }]), context: nil)

      expect(delivery.fetch(:content).map { |block| block["tool_use_id"] }).to eq(["tu_1"])
      expect(delivery.fetch(:causal_parents)).to eq(["blake3:q1"])
    end

    it "harvests exactly once: the next delivery cites nothing" do
      subject = runner(handover_tool("ask_human", ["blake3:q1"]))
      subject.delivery(tool_response(["tu_1", "ask_human", { "question" => "q?" }]), context: nil)

      second = subject.delivery(tool_response(["tu_2", "ask_human", { "question" => "again?" }]), context: nil)

      expect(second.fetch(:causal_parents)).to eq([])
    end

    it "collects across every hand-over tool and ignores tools without the message" do
      subject = runner(plain_tool("echo"), handover_tool("ask_a", ["blake3:q1"]),
                       handover_tool("ask_b", ["blake3:q2"]))

      delivery = subject.delivery(tool_response(["tu_1", "echo", {}]), context: nil)

      # Toolset iterates name-sorted, so the collection order is deterministic.
      expect(delivery.fetch(:causal_parents)).to eq(%w[blake3:q1 blake3:q2])
    end

    it "yields causal_parents: [] for a toolset with nothing to hand over (ordinary turns unmoved)" do
      delivery = runner(plain_tool("echo")).delivery(tool_response(["tu_1", "echo", {}]), context: nil)

      expect(delivery.fetch(:causal_parents)).to eq([])
    end

    it "yields causal_parents: [] under the default (empty) toolset" do
      delivery = described_class.new(handler: echoing_handler)
                                .delivery(tool_response(["tu_1", "echo", {}]), context: nil)

      expect(delivery.fetch(:causal_parents)).to eq([])
    end
  end
end
