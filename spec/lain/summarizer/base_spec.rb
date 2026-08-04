# frozen_string_literal: true

# The contract a user summarizer implements, and the value both of its methods
# receive. A summarizer is PURE and SYNCHRONOUS -- text in, text out, no
# provider and no IO -- which is the whole value of this tier: it costs no
# tokens and no latency.
RSpec.describe Lain::Summarizer::Base do
  subject(:summarizer) { described_class.new("empty") }

  let(:result) { Lain::Summarizer::Result.new(tool_name: "bash", text: "Coverage report generated") }

  it "refuses #suitable? loudly, naming the summarizer that did not implement it" do
    expect { summarizer.suitable?(result) }
      .to raise_error(NotImplementedError, /"empty".*suitable\?/)
  end

  it "refuses #compact loudly, naming the summarizer that did not implement it" do
    expect { summarizer.compact(result) }
      .to raise_error(NotImplementedError, /"empty".*compact/)
  end

  it "knows its declared name" do
    expect(summarizer.name).to eq("empty")
  end

  it "is frozen -- a summarizer is pure, so it carries no state to mutate" do
    expect(summarizer).to be_frozen
  end

  describe Lain::Summarizer::Result do
    subject(:result) { described_class.new(tool_name: "bash", text: "1 example, 0 failures") }

    it "carries the tool name and the text -- some kinds are told apart by tool, some only by content" do
      expect(result.tool_name).to eq("bash")
      expect(result.text).to eq("1 example, 0 failures")
    end

    it "normalizes a Symbol tool name so the value reads the same however it was built" do
      expect(described_class.new(tool_name: :bash, text: "x").tool_name).to eq("bash")
    end

    it "is deeply frozen, so `Ractor.shareable?` holds" do
      expect(described_class.new(tool_name: :bash, text: +"mutable")).to be_deeply_frozen
    end
  end
end
