# frozen_string_literal: true

require "lain/effect"
require "lain/handler"
require "lain/handler/live"
require "lain/toolset"

RSpec.describe Lain::Handler::Approving do
  def tool(tool_name, gated: false, &body)
    Class.new(Lain::Tool) do
      define_method(:name) { tool_name.to_s }
      define_method(:description) { "the #{tool_name} tool" }
      define_method(:requires_approval?) { gated }
      def input_schema = { type: :object, properties: { text: { type: :string } }, required: [] }
      define_method(:perform, &body)
    end.new
  end

  let(:safe) { tool(:safe) { |input, _invocation| Lain::Tool::Result.ok(input.fetch(:text, "safe")) } }
  let(:dangerous) { tool(:dangerous, gated: true) { |input, _invocation| Lain::Tool::Result.ok(input.fetch(:text, "ran")) } }
  let(:toolset) { Lain::Toolset.new([safe, dangerous]) }
  let(:live) { Lain::Handler::Live.new(toolset: toolset) }

  def tool_call(name, input = {}, id: "tu_1")
    Lain::Effect::ToolCall.new(tool_use_id: id, name: name, input: input)
  end

  describe "ungated tools" do
    it "falls straight through to inner without consulting the policy" do
      # A bare double with nothing stubbed: if Approving ever asked it
      # anything, this would raise "received unexpected message" and fail
      # the example -- which is the point.
      untouched_policy = double("never consulted")
      approving = described_class.new(toolset: toolset, policy: untouched_policy, inner: live)

      expect(approving.call(tool_call("safe"))).to eq(Lain::Tool::Result.ok("safe"))
    end
  end

  describe "a gated tool, denied" do
    it "returns an is_error Result rather than raising, and never reaches inner" do
      approving = described_class.new(toolset: toolset, policy: described_class::DenyAll.new, inner: live)

      result = approving.call(tool_call("dangerous"))

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to match(/denied/)
    end
  end

  describe "a gated tool, approved" do
    it "delegates to inner and returns its Result" do
      approving = described_class.new(toolset: toolset, policy: described_class::ApproveAll.new, inner: live)

      expect(approving.call(tool_call("dangerous", { text: "went through" })))
        .to eq(Lain::Tool::Result.ok("went through"))
    end
  end

  describe "DenyAll is the default policy" do
    it "denies a gated call when no policy is given" do
      approving = described_class.new(toolset: toolset, inner: live)
      expect(approving.call(tool_call("dangerous"))).to have_attributes(is_error: true)
    end
  end

  describe "an explicit Effect::Approval wrapper" do
    it "is gated regardless of the wrapped tool's own tier" do
      wrapped = Lain::Effect::Approval.new(effect: tool_call("safe"))
      approving = described_class.new(toolset: toolset, policy: described_class::DenyAll.new, inner: live)

      expect(approving.call(wrapped)).to have_attributes(is_error: true, content: /denied/)
    end

    it "runs the inner effect once approved" do
      wrapped = Lain::Effect::Approval.new(effect: tool_call("safe", { text: "unwrapped" }))
      approving = described_class.new(toolset: toolset, policy: described_class::ApproveAll.new, inner: live)

      expect(approving.call(wrapped)).to eq(Lain::Tool::Result.ok("unwrapped"))
    end
  end

  describe "an unknown tool named in a bare ToolCall" do
    it "is not gated, and falls through to inner to report the usual unknown-tool error" do
      approving = described_class.new(toolset: toolset, policy: described_class::DenyAll.new, inner: live)

      result = approving.call(tool_call("ghost"))
      expect(result).to have_attributes(is_error: true, content: /no tool named/)
    end
  end

  describe "an approved effect with no inner handler" do
    it "raises UnhandledEffect rather than silently doing nothing" do
      approving = described_class.new(toolset: toolset, policy: described_class::ApproveAll.new)
      expect { approving.call(tool_call("dangerous")) }.to raise_error(Lain::Handler::UnhandledEffect)
    end
  end

  describe "the policy receives the unwrapped effect and the context" do
    it "hands the policy the ToolCall itself, not the Approval wrapper" do
      seen = nil
      policy = lambda do |effect, _context|
        seen = effect
        true
      end
      wrapped = Lain::Effect::Approval.new(effect: tool_call("safe"))
      approving = described_class.new(toolset: toolset, policy: policy, inner: live)

      approving.call(wrapped, "some context")

      expect(seen).to be_a(Lain::Effect::ToolCall)
      expect(seen.name).to eq("safe")
    end
  end
end
