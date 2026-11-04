# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::RunAllowance do
  subject(:record) { described_class.new(iterations: 103) }

  it "journals as a run_allowance record naming the iteration ceiling granted" do
    expect(JSON.generate(record.to_journal)).to eq('{"type":"run_allowance","iterations":103}')
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(record)).to be(true)
  end

  it "reads back from the journal as the same record" do
    expect(Lain::Telemetry.read(JSON.parse(JSON.generate(record.to_journal)))).to eq(record)
  end
end
