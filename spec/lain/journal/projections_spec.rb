# frozen_string_literal: true

RSpec.describe Lain::Journal::Projections do
  digest = "blake3:#{"c" * 64}"
  records = [
    Lain::Telemetry::TurnLabeled.new(digest:, label: "first"),
    Lain::Telemetry::Untyped.new(fields: { "type" => "turn", "digest" => digest }),
    Lain::Telemetry::TurnLabeled.new(digest:, label: "second")
  ]

  tally = Class.new(Lain::Journal::Projection) do
    define_singleton_method(:unit) { new(0) }
    define_method(:step) { |_record| self.class.new(value + 1) }
  end
  labels = Class.new(Lain::Journal::Projection) do
    define_singleton_method(:unit) { new({}) }
    define_method(:step) do |record|
      record.is_a?(Lain::Telemetry::TurnLabeled) ? self.class.new(value.merge(record.digest => record.label)) : self
    end
  end
  types = Class.new(Lain::Journal::Projection) do
    define_singleton_method(:unit) { new([]) }
    define_method(:step) { |record| self.class.new([*value, record.class]) }
  end

  def walked_once(records)
    count = 0
    enumerator = Enumerator.new do |yielder|
      count += 1
      records.each { |record| yielder << record }
    end
    [enumerator, -> { count }]
  end

  it "answers each member's value as the member built alone, walking the records once" do
    enumerator, walks = walked_once(records)
    composite = described_class.of(tally: tally.unit, labels: labels.unit, types: types.unit).over(enumerator)
    expect(%i[tally labels types].map { |key| composite[key] }).to eq([tally, labels, types].map { _1.over(records) })
    expect(walks.call).to eq(1)
  end

  it "steps to a new composite and leaves the old one as it was" do
    before = described_class.of(tally: tally.unit)
    after = before.step(records.first)
    expect([before[:tally].value, after[:tally].value]).to eq([0, 1])
    expect([before, after]).to all(satisfy { |composite| Ractor.shareable?(composite) })
  end

  it "answers itself when no member moved" do
    composite = described_class.of(labels: labels.unit)
    expect(composite.step(records[1])).to be(composite)
  end

  it "refuses a key it does not hold" do
    expect { described_class.of(tally: tally.unit)[:tallly] }.to raise_error(KeyError)
  end

  it "folds an empty composite as its own unit" do
    expect(described_class.over(records)).to eq(described_class.of)
  end
end
