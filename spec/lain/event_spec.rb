# frozen_string_literal: true

require "json"

require "lain/event"

RSpec.describe Lain::Event do
  describe Lain::Event::ToolOutput do
    subject(:event) { described_class.new(tool_use_id: "t1", stream: :stdout, bytes: "hi") }

    it "rejects an unknown stream" do
      expect { described_class.new(tool_use_id: "t", stream: :nope, bytes: "x") }
        .to raise_error(ArgumentError)
    end

    it "is a frozen value object with structural equality" do
      twin = described_class.new(tool_use_id: "t1", stream: :stdout, bytes: "hi")
      expect(event).to eq(twin)
      expect(event).to be_frozen
      expect(event.hash).to eq(twin.hash)
    end

    it "is Ractor-shareable (no reachable mutable state)" do
      expect(Ractor.shareable?(event)).to be(true)
    end

    describe "#to_journal" do
      it "is a JSON object of the attributes tagged with a snake_case type" do
        expect(event.to_journal).to eq(
          "type" => "tool_output", "tool_use_id" => "t1", "stream" => :stdout, "bytes" => "hi"
        )
      end

      it "round-trips through JSON to a parseable line" do
        expect(JSON.parse(JSON.generate(event.to_journal))).to include(
          "type" => "tool_output", "stream" => "stdout"
        )
      end
    end
  end

  describe Lain::Event::Dropped do
    it "carries a positive count" do
      expect(described_class.new(count: 3).count).to eq(3)
    end

    it "rejects a non-positive count" do
      expect { described_class.new(count: 0) }.to raise_error(ArgumentError)
      expect { described_class.new(count: -1) }.to raise_error(ArgumentError)
    end

    it "is a frozen value object" do
      expect(described_class.new(count: 1)).to be_frozen
    end

    it "journals as a dropped marker" do
      expect(described_class.new(count: 5).to_journal).to eq("type" => "dropped", "count" => 5)
    end
  end
end
