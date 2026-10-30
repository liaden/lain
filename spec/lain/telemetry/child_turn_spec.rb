# frozen_string_literal: true

RSpec.describe Lain::Telemetry::ChildTurn do
  def record(**over)
    described_class.new(digest: "blake3:d", kind: :turn, from: "child", to: nil, render_parent: "blake3:p",
                        payload: { "role" => "assistant", "n" => [1, { "k" => "v" }] }, causal_parents: ["blake3:p"],
                        correlation: nil, **over)
  end

  it "journals under its own type with every field" do
    expect(record.to_journal).to eq("type" => "child_turn", "digest" => "blake3:d", "kind" => :turn,
                                    "from" => "child", "to" => nil, "render_parent" => "blake3:p",
                                    "payload" => { "role" => "assistant", "n" => [1, { "k" => "v" }] },
                                    "causal_parents" => ["blake3:p"], "correlation" => nil)
  end

  it "is shareable across Ractors, even when built from mutable values" do
    expect(record(digest: +"blake3:d", payload: { +"role" => +"assistant" })).to be_deeply_frozen
  end

  it "takes the kind as a symbol" do
    expect(record(kind: "turn").kind).to eq(:turn)
  end
end
