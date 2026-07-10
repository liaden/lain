# frozen_string_literal: true

require "lain/agent"

RSpec.describe Lain::Agent do
  # ---- fixtures -------------------------------------------------------------

  echo_tool = Class.new(Lain::Tool) do
    def name = "echo"
    def description = "Echoes its input back."
    def input_schema = { type: :object, properties: { text: { type: :string } }, required: [:text] }

    def perform(input, _context) = Lain::Tool::Result.ok(input.fetch("text"))
  end

  boom_tool = Class.new(Lain::Tool) do
    def name = "boom"
    def description = "Always explodes."
    def input_schema = { type: :object, properties: {} }

    def perform(_input, _context) = raise("kaboom")
  end

  let(:toolset) { Lain::Toolset.new([echo_tool.new, boom_tool.new]) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }

  def agent(responses, **overrides)
    described_class.new(
      provider: Lain::Provider::Mock.new(responses: Array(responses)),
      toolset: toolset,
      context: context,
      **overrides
    )
  end

  def text_response(text = "done", stop_reason: :end_turn)
    Lain::Response.new(content: [{ "type" => "text", "text" => text }], stop_reason: stop_reason)
  end

  def tool_response(*calls)
    blocks = [{ "type" => "thinking", "thinking" => "considering" }]
    blocks += calls.map do |(id, name, input)|
      { "type" => "tool_use", "id" => id, "name" => name, "input" => input }
    end
    Lain::Response.new(content: blocks, stop_reason: :tool_use)
  end

  # ---- the loop -------------------------------------------------------------

  describe "#ask" do
    it "appends the user turn and settles on end_turn" do
      a = agent(text_response("hello"))
      response = a.ask("hi")

      expect(response.text).to eq("hello")
      expect(a).to be_done
      expect(a.timeline.to_a.map(&:role)).to eq(%w[user assistant])
    end

    it "accumulates usage across turns" do
      usage = Lain::Usage.new(input_tokens: 10, output_tokens: 5)
      a = agent([tool_response(%w[tu_1 echo], { "text" => "x" }),
                 Lain::Response.new(content: [], stop_reason: :end_turn, usage: usage)])
      a.ask("hi")
      expect(a.usage.output_tokens).to eq(5)
    end
  end

  # ---- correctness gates ----------------------------------------------------

  describe "gate 1: the FULL response content is appended" do
    it "retains thinking and tool_use blocks on the assistant turn" do
      a = agent([tool_response(["tu_1", "echo", { "text" => "x" }]), text_response])
      a.ask("hi")

      assistant = a.timeline.to_a.find { |turn| turn.role == "assistant" }
      expect(assistant.content.map { |b| b["type"] }).to eq(%w[thinking tool_use])
    end
  end

  describe "gate 2: all tool_results return in ONE user message" do
    it "appends a single user turn holding every result" do
      a = agent([tool_response(["tu_1", "echo", { "text" => "a" }], ["tu_2", "echo", { "text" => "b" }]),
                 text_response])
      a.ask("hi")

      results_turn = a.timeline.to_a[2]
      expect(results_turn.role).to eq("user")
      expect(results_turn.content.map { |b| b["type"] }).to eq(%w[tool_result tool_result])
      expect(a.timeline.to_a.map(&:role)).to eq(%w[user assistant user assistant])
    end
  end

  describe "gate 3: a raising tool becomes an error result, and the loop continues" do
    it "reports is_error and keeps going" do
      a = agent([tool_response(["tu_1", "boom", {}]), text_response("recovered")])
      response = a.ask("hi")

      result_block = a.timeline.to_a[2].content.first
      expect(result_block["is_error"]).to be(true)
      expect(result_block["content"]).to match(/kaboom/)
      expect(response.text).to eq("recovered")
      expect(a).to be_done
    end

    it "reports an unknown tool as an error rather than crashing" do
      a = agent([tool_response(["tu_1", "nonexistent", {}]), text_response])
      a.ask("hi")

      expect(a.timeline.to_a[2].content.first["is_error"]).to be(true)
      expect(a).to be_done
    end
  end

  describe "gate 4: every tool_result carries its matching tool_use_id" do
    it "pairs ids one for one" do
      a = agent([tool_response(["tu_1", "echo", { "text" => "a" }], ["tu_2", "echo", { "text" => "b" }]),
                 text_response])
      a.ask("hi")

      ids = a.timeline.to_a[2].content.map { |b| b["tool_use_id"] }
      expect(ids).to eq(%w[tu_1 tu_2])
    end
  end

  describe "gate 5: tool input reaches the tool as a parsed object" do
    it "hands the tool a Hash, never a JSON string" do
      seen = nil
      capturing = Class.new(Lain::Tool) do
        define_method(:name) { "capture" }
        define_method(:description) { "captures" }
        define_method(:input_schema) { { type: :object, properties: {} } }
        define_method(:perform) do |input, _context|
          seen = input
          Lain::Tool::Result.ok("ok")
        end
      end

      a = described_class.new(
        provider: Lain::Provider::Mock.new(
          responses: [tool_response(["tu_1", "capture", { "path" => "a.rb" }]), text_response]
        ),
        toolset: Lain::Toolset.new([capturing.new]),
        context: context
      )
      a.ask("hi")

      expect(seen).to be_a(Hash)
      expect(seen).to eq({ "path" => "a.rb" })
    end
  end

  describe "gate 6: stop_reason handling is total" do
    it "settles done on end_turn" do
      expect(agent(text_response).tap { |a| a.ask("hi") }).to be_done
    end

    # Easy to forget, and it really does occur.
    it "settles done on stop_sequence" do
      a = agent(text_response("x", stop_reason: :stop_sequence))
      a.ask("hi")
      expect(a).to be_done
    end

    it "fails on refusal, recording why" do
      a = agent(text_response("", stop_reason: :refusal))
      a.ask("hi")
      expect(a).to be_failed
      expect(a.failure_reason).to match(/refused/)
    end

    it "fails on max_tokens" do
      a = agent(text_response("", stop_reason: :max_tokens))
      a.ask("hi")
      expect(a).to be_failed
      expect(a.failure_reason).to match(/max_tokens/)
    end

    # The wire enums are non-exhaustive. An unrecognized value must fail loudly,
    # not fall through a `case` and quietly do nothing.
    it "fails on an unrecognized stop_reason" do
      a = agent(Lain::Response.new(content: [], stop_reason: "something_new_in_2027"))
      a.ask("hi")
      expect(a).to be_failed
      expect(a.failure_reason).to match(/unrecognized/)
    end

    # A server-side tool is mid-flight; resend and let it continue.
    it "re-requests on pause_turn rather than settling" do
      provider = Lain::Provider::Mock.new(
        responses: [text_response("", stop_reason: :pause_turn), text_response("finished")]
      )
      a = described_class.new(provider: provider, toolset: toolset, context: context)
      response = a.ask("hi")

      expect(provider.call_count).to eq(2)
      expect(response.text).to eq("finished")
      expect(a).to be_done
    end
  end

  describe "gate 7: the loop is bounded" do
    it "raises once max_iterations is reached" do
      a = agent([tool_response(["tu_1", "echo", { "text" => "loop" }])],
                budget: Lain::Agent::Budget.new(max_iterations: 3))
      expect { a.ask("hi") }.to raise_error(described_class::BudgetExceeded, /3 iterations/)
    end

    it "raises once the token ceiling is passed" do
      usage = Lain::Usage.new(input_tokens: 100, output_tokens: 100)
      a = agent([Lain::Response.new(content: [], stop_reason: :end_turn, usage: usage)],
                budget: Lain::Agent::Budget.new(max_total_tokens: 50))
      expect { a.ask("hi") }.to raise_error(described_class::BudgetExceeded, /ceiling is 50/)
    end

    # A budget stop is the harness's decision, not the model's output; a refusal
    # is the opposite. They must not be conflated.
    it "does not conflate a budget stop with a refusal" do
      a = agent(text_response("", stop_reason: :refusal))
      expect { a.ask("hi") }.not_to raise_error
      expect(a).to be_failed
    end
  end

  describe "state machine" do
    it "starts awaiting_user" do
      expect(agent(text_response).state).to eq(:awaiting_user)
    end

    it "exposes every declared state" do
      expect(described_class::STATES)
        .to contain_exactly(:awaiting_user, :awaiting_model, :awaiting_tools,
                            :awaiting_approval, :done, :failed)
    end
  end

  describe "#rewind" do
    it "moves the head back and reopens the loop" do
      a = agent([tool_response(["tu_1", "echo", { "text" => "a" }]), text_response])
      a.ask("hi")
      expect(a.timeline.length).to eq(4)

      a.rewind(2)
      expect(a.timeline.length).to eq(2)
      expect(a.state).to eq(:awaiting_user)
    end
  end
end
