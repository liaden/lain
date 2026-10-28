# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::ClosureRecord do
  subject(:record) do
    described_class.new(closure_digest: "blake3:c", step_id: "s1", plan_digest: "blake3:p", size: "small",
                        chunk_turn_digests: %w[blake3:a blake3:b])
  end

  it "prints its journal line" do
    expect(JSON.generate(record.to_journal)).to eq(
      '{"type":"closure_record","closure_digest":"blake3:c","step_id":"s1","plan_digest":"blake3:p",' \
      '"size":"small","chunk_turn_digests":["blake3:a","blake3:b"]}'
    )
  end

  it "is shareable when built from mutable input" do
    mutable = described_class.new(closure_digest: +"blake3:c", step_id: +"s1", plan_digest: +"blake3:p",
                                  size: +"small", chunk_turn_digests: [+"blake3:a"])

    expect(mutable).to be_deeply_frozen
  end

  it "refuses a record naming no closure" do
    expect do
      described_class.new(closure_digest: nil, step_id: "s1", plan_digest: "blake3:p", size: "small",
                          chunk_turn_digests: [])
    end.to raise_error(ArgumentError, /closure_digest must name the closure/)
  end

  it "interns the chunk digests, so equal records share their Strings" do
    build = lambda {
      described_class.new(closure_digest: "c", step_id: "s", plan_digest: "p", size: "x",
                          chunk_turn_digests: [+"blake3:a"])
    }

    expect(build.call.chunk_turn_digests.first).to equal(build.call.chunk_turn_digests.first)
  end

  it "refuses a nil chunk list" do
    expect do
      described_class.new(closure_digest: "c", step_id: "s", plan_digest: "p", size: "x", chunk_turn_digests: nil)
    end
      .to raise_error(ArgumentError, /chunk_turn_digests/)
  end
end
