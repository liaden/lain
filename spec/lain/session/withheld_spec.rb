# frozen_string_literal: true

RSpec.describe Lain::Session::Withheld do
  subject(:ledger) { described_class.new }

  let(:source) { described_class::Source }

  it "answers for exactly the sources it was given" do
    ledger.record(source.file("/tmp/.env"))

    expect(ledger.withheld?(source.file("/tmp/.env"))).to be(true)
    expect(ledger.withheld?(source.file("/tmp/other"))).to be(false)
  end

  it "keeps a file and a memory item of the same key apart" do
    ledger.record(source.memory("notes"))

    expect(ledger.withheld?(source.memory("notes"))).to be(true)
    expect(ledger.withheld?(source.file("notes"))).to be(false)
  end

  it "is idempotent" do
    2.times { ledger.record(source.memory("notes")) }

    expect(ledger.withheld?(source.memory("notes"))).to be(true)
  end

  it "refuses a source of a kind it does not know" do
    expect { source.new(kind: :stub, key: "k") }.to raise_error(ArgumentError, /kind/)
  end

  it "makes sources that are deeply frozen values" do
    expect(source.file(+"/tmp/x")).to be_deeply_frozen
  end
end
