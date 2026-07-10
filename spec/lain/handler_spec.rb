# frozen_string_literal: true

require "lain/handler"
require "lain/toolset"

RSpec.describe Lain::Handler do
  def tool(tool_name, &body)
    Class.new(Lain::Tool) do
      define_method(:name) { tool_name.to_s }
      define_method(:description) { "the #{tool_name} tool" }
      def input_schema = { type: :object, properties: { text: { type: :string } }, required: [] }
      define_method(:perform, &body)
    end.new
  end

  let(:echo) { tool(:echo) { |input, _context| Lain::Tool::Result.ok(input.fetch(:text, "")) } }
  let(:toolset) { Lain::Toolset.new([echo]) }

  def tool_call(name, input = {}, id: "tu_1")
    Lain::Effect::ToolCall.new(tool_use_id: id, name: name, input: input)
  end

  describe Lain::Handler::Live do
    subject(:handler) { described_class.new(toolset: toolset) }

    it "dispatches a ToolCall to the tool the Toolset holds" do
      expect(handler.call(tool_call("echo", { text: "hi" }))).to eq(Lain::Tool::Result.ok("hi"))
    end

    describe "correctness gate 3 -- a failure never raises past the loop" do
      it "turns a raising tool into an error Result" do
        boom = tool(:boom) { |_input, _context| raise "kaboom" }
        h = described_class.new(toolset: Lain::Toolset.new([boom]))
        result = h.call(tool_call("boom"))
        expect(result).to have_attributes(is_error: true)
        expect(result.content).to match(/kaboom/)
      end

      it "turns a contract violation into an error Result" do
        gated = Class.new(Lain::Tool) do
          def name = "gated"
          def description = "d"
          requires("never") { |_input, _context| false }
          def perform(_input, _context) = Lain::Tool::Result.ok("unreachable")
        end.new
        h = described_class.new(toolset: Lain::Toolset.new([gated]))
        expect(h.call(tool_call("gated"))).to have_attributes(is_error: true, content: /precondition failed/)
      end

      it "turns an invalid input into an error Result rather than dispatching" do
        strict = tool(:strict) { |_input, _context| Lain::Tool::Result.ok("ran") }
        allow(strict).to receive(:input_schema).and_return(
          { type: :object, properties: { text: { type: :string } }, required: [:text] }
        )
        h = described_class.new(toolset: Lain::Toolset.new([strict]))
        expect(h.call(tool_call("strict", {}))).to have_attributes(is_error: true, content: /text is required/)
      end

      it "reports a call to an unknown tool as an error Result" do
        expect(handler.call(tool_call("ghost"))).to have_attributes(is_error: true, content: /no tool named/)
      end
    end

    it "unwraps an Approval and runs the inner effect (executor of last resort)" do
      gated = Lain::Effect::Approval.new(effect: tool_call("echo", { text: "yo" }))
      expect(handler.call(gated)).to eq(Lain::Tool::Result.ok("yo"))
    end

    it "delegates an effect it does not handle to its inner handler" do
      # A catch-all inner handler that Live can fall back to for effect kinds Live
      # itself declines (Live handles only ToolCall/Approval).
      catch_all = Class.new(Lain::Handler) do
        def handles?(_effect) = true
        def perform(_effect, _context) = Lain::Tool::Result.ok("from inner")
      end.new
      composed = described_class.new(toolset: toolset, inner: catch_all)
      unknown = Struct.new(:kind).new(:model)
      expect(composed.call(unknown)).to eq(Lain::Tool::Result.ok("from inner"))
    end

    it "raises UnhandledEffect when nothing in the chain can interpret the effect" do
      unknown = Struct.new(:kind).new(:model)
      expect { handler.call(unknown) }.to raise_error(Lain::Handler::UnhandledEffect)
    end
  end

  describe Lain::Handler::Mock do
    it "resolves by tool name" do
      mock = described_class.new(results: { "echo" => Lain::Tool::Result.ok("canned") })
      expect(mock.call(tool_call("echo"))).to eq(Lain::Tool::Result.ok("canned"))
    end

    it "resolves by tool_use_id" do
      mock = described_class.new(results: { "tu_42" => Lain::Tool::Result.ok("by id") })
      expect(mock.call(tool_call("echo", {}, id: "tu_42"))).to eq(Lain::Tool::Result.ok("by id"))
    end

    it "coerces a bare String canned value into a successful Result" do
      mock = described_class.new(results: { "echo" => "just text" })
      expect(mock.call(tool_call("echo"))).to eq(Lain::Tool::Result.ok("just text"))
    end

    it "lets a block resolve results from the effect" do
      mock = described_class.new { |effect, _context| Lain::Tool::Result.ok(effect.input[:text].upcase) }
      expect(mock.call(tool_call("echo", { text: "loud" }))).to eq(Lain::Tool::Result.ok("LOUD"))
    end

    it "falls back to an error Result when nothing matches" do
      expect(described_class.new.call(tool_call("echo"))).to have_attributes(is_error: true)
    end
  end

  describe "composition into a stack terminator" do
    it "adapts a handler into an env -> env app via #to_app" do
      app = Lain::Handler::Live.new(toolset: toolset).to_app
      env = { effect: tool_call("echo", { text: "hi" }), context: nil }
      expect(app.call(env)[:result]).to eq(Lain::Tool::Result.ok("hi"))
    end
  end
end
