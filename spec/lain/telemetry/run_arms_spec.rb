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
end
