# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::ContextDerived do
  it "prints its journal line with every field set" do
    record = described_class.new(source_head: "blake3:s", derived_head: "blake3:d", strategy: "summary",
                                 spans: [%w[blake3:a blake3:b]], cut: :offered, moved: 4, keep_last: 6,
                                 compaction_cut: "blake3:cc", mid_task: true)

    expect(JSON.generate(record.to_journal)).to eq(
      '{"type":"context_derived","source_head":"blake3:s","derived_head":"blake3:d","strategy":"summary",' \
      '"spans":[["blake3:a","blake3:b"]],"cut":"offered","moved":4,"keep_last":6,' \
      '"compaction_cut":"blake3:cc","mid_task":true}'
    )
  end

  it "prints null for every optional field" do
    record = described_class.new(source_head: nil, derived_head: nil, strategy: "summary", spans: [], cut: :empty)

    expect(JSON.generate(record.to_journal)).to eq(
      '{"type":"context_derived","source_head":null,"derived_head":null,"strategy":"summary","spans":[],' \
      '"cut":"empty","moved":0,"keep_last":null,"compaction_cut":null,"mid_task":null}'
    )
  end

  it "names an anonymous strategy class rather than its address" do
    record = described_class.new(source_head: nil, derived_head: nil, strategy: Class.new, spans: [], cut: :empty)

    expect(record.strategy).to eq("(anonymous strategy)")
  end

  it "is shareable when built from mutable input" do
    record = described_class.new(source_head: +"blake3:s", derived_head: +"blake3:d", strategy: +"summary",
                                 spans: [[+"blake3:a", +"blake3:b"]], cut: :offered, compaction_cut: +"blake3:cc")

    expect(record).to be_deeply_frozen
  end

  it "refuses a cut outside empty, declined and offered" do
    expect do
      described_class.new(source_head: nil, derived_head: nil, strategy: "summary", spans: [], cut: :bogus)
    end.to raise_error(ArgumentError, %r{cut must be one of empty/declined/offered})
  end

  it "interns the strategy and the compaction cut" do
    build = lambda do
      described_class.new(source_head: nil, derived_head: nil, strategy: +"summary", spans: [], cut: :empty,
                          compaction_cut: +"blake3:cc")
    end

    expect(build.call.strategy).to equal(build.call.strategy)
    expect(build.call.compaction_cut).to equal(build.call.compaction_cut)
  end
end
