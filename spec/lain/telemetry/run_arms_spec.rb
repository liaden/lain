# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::RunArms do
  subject(:event) { described_class.new(arms: { "confine" => "reader" }) }

  it "journals as a run_arms record naming the arms that are on" do
    expect(JSON.parse(JSON.generate(event.to_journal))).to eq("type" => "run_arms", "arms" => { "confine" => "reader" })
  end

  it "is deeply frozen, whatever it was handed" do
    given = { "confine" => +"reader" }

    expect(Ractor.shareable?(described_class.new(arms: given))).to be(true)
    expect(given["confine"]).not_to be_frozen
  end

  describe "settled record" do
    it "journals byte for byte with every field set" do
      record = described_class.new(arms: { "confine" => "reader", "judge" => true })
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"run_arms","arms":{"confine":"reader","judge":true}}'
      )
    end

    it "is deeply frozen when built from mutable input" do
      given = {
        arms: { "confine" => "reader", "judge" => true }
      }
      mutable = given.transform_values { |value| value.is_a?(String) ? value.dup : value }
      expect(described_class.new(**mutable)).to be_deeply_frozen
    end

    it "refuses a missing arms, naming it" do
      given = {
        arms: { "confine" => "reader", "judge" => true }
      }
      expect { described_class.new(**given.except(:arms)) }.to raise_error(ArgumentError, /arms/)
    end

    it "reads nil arms as none and refuses a non-Hash" do
      expect(described_class.new(arms: nil).arms).to eq({})
      expect { described_class.new(arms: 5) }.to raise_error(NoMethodError)
    end
  end
end
