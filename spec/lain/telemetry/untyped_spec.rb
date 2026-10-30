# frozen_string_literal: true

RSpec.describe Lain::Telemetry::Untyped do
  subject(:record) { described_class.new(fields: given) }

  let(:given) { { "type" => +"turn", "digest" => +"blake3:t", "meta" => { "k" => +"v" } } }

  it "answers its type and any key of the line it carries" do
    expect(record.type).to eq("turn")
    expect(record["digest"]).to eq("blake3:t")
    expect(record["absent"]).to be_nil
  end

  it "is deeply frozen without freezing the hash it was given" do
    expect(record).to be_deeply_frozen
    expect(given["meta"]).not_to be_frozen
  end

  it "keys a Hash and dedupes like any value" do
    twin = described_class.new(fields: given)

    expect({ record => 1 }[twin]).to eq(1)
    expect([record, twin].uniq).to eq([record])
  end

  it "refuses a line with no type, since every record names one" do
    expect { described_class.new(fields: { "digest" => "d" }).type }.to raise_error(KeyError, /type/)
  end
end
