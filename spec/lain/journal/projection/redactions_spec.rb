# frozen_string_literal: true

RSpec.describe Lain::Journal::Projection::Redactions do
  telemetry = Lain::Telemetry
  source = ->(regions) { telemetry::SourceMasked.new(tool_use_id: "tu_1", kind: :file, key: ".env", regions:) }
  command = ->(regions) { telemetry::CommandRedacted.new(tool_use_id: "tu_2", regions:) }
  search = ->(regions) { telemetry::SearchRedacted.new(tool_use_id: "tu_3", path: "a.rb", regions:, released: 0) }
  released = lambda do |regions|
    telemetry::ReadReleased.new(tool_use_id: "tu_4", path: ".env", regions:, requester: "agent", surface: "tty")
  end
  turn = telemetry::Untyped.new(fields: { "type" => "turn", "digest" => "d1", "parent" => nil })

  palette = [source.call(1), command.call(2), search.call(4), released.call(3), released.call(1), turn]
  g = PropCheck::Generators
  record_lists = g.array(g.one_of(*palette.map { g.constant(_1) }), min: 0, max: 5)

  describe "the laws" do
    include_examples "an incremental fold", projection: described_class, generator: record_lists, samples: 6
  end

  it "counts masked regions across the 3 redaction records, and released regions apart" do
    redactions = described_class.over([source.call(1), command.call(2), search.call(4), released.call(3), turn])

    expect([redactions.masked, redactions.released]).to eq([7, 3])
  end

  it "answers a session with none as no regions" do
    expect(described_class.over([turn]).value).to eq({ masked: 0, released: 0 })
  end

  it "names the record types it counts as masked" do
    expect(described_class::REDACTIONS).to eq(%w[source_masked command_redacted search_redacted])
  end

  it "combines 2 halves into the whole by adding both counts" do
    left = described_class.over([source.call(1), released.call(3)])
    right = described_class.over([search.call(4)])

    expect(left.combine(right)).to eq(described_class.over([source.call(1), released.call(3), search.call(4)]))
  end

  it "answers itself for a record it does not count" do
    redactions = described_class.over([source.call(1)])

    expect(redactions.step(turn)).to be(redactions)
  end
end
