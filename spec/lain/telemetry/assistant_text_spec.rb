# frozen_string_literal: true

RSpec.describe Lain::Telemetry::AssistantText do
  describe "settled record" do
    it "journals byte for byte with every field set" do
      record = described_class.new(text: "I will read the file.")
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"assistant_text","text":"I will read the file."}'
      )
    end

    it "is deeply frozen when built from mutable input" do
      given = {
        text: "I will read the file."
      }
      mutable = given.transform_values { |value| value.is_a?(String) ? value.dup : value }
      expect(described_class.new(**mutable)).to be_deeply_frozen
    end

    it "refuses a missing text, naming it" do
      given = {
        text: "I will read the file."
      }
      expect { described_class.new(**given.except(:text)) }.to raise_error(ArgumentError, /text/)
    end

    it "coerces its text to a String as before" do
      expect(described_class.new(text: nil).text).to eq("")
      expect(described_class.new(text: 7).text).to eq("7")
    end
  end
end
