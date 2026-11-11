# frozen_string_literal: true

RSpec.describe Lain::Journal::Projection::Usage do
  paid = lambda do |input, output, command: nil, role: nil, requester: nil|
    Lain::Telemetry::TurnUsage.new(digest: "blake3:#{input}#{output}", model: "m", stop_reason: :end_turn,
                                   usage: { input_tokens: input, output_tokens: output },
                                   command:, role:, requester:)
  end
  turn = Lain::Telemetry::Untyped.new(fields: { "type" => "turn", "digest" => "d1", "parent" => nil })

  palette = [paid.call(10, 1, command: "plan"), paid.call(20, 2, command: "plan", role: "reviewer"),
             paid.call(30, 3), paid.call(5, 5, requester: :auto_approver), turn]
  g = PropCheck::Generators
  record_lists = g.array(g.one_of(*palette.map { g.constant(_1) }), min: 0, max: 5)

  describe "the laws" do
    include_examples "an incremental fold", projection: described_class, generator: record_lists, samples: 6
  end

  it "folds a usage by the command and role that paid it" do
    folded = described_class.over([paid.call(10, 1, command: "plan"), paid.call(5, 2, command: "plan"),
                                   paid.call(7, 3, command: "plan", role: "reviewer")])

    expect(folded.value).to eq(
      %w[plan agent] => Lain::Usage.new(input_tokens: 15, output_tokens: 3),
      %w[plan reviewer] => Lain::Usage.new(input_tokens: 7, output_tokens: 3)
    )
  end

  it "files a record naming no command under none, and a requester that is not the agent as its role" do
    folded = described_class.over([paid.call(30, 3), paid.call(5, 5, requester: :auto_approver)])

    expect(folded.value.keys).to contain_exactly([nil, "agent"], [nil, "auto_approver"])
  end

  it "counts turn_usage records only" do
    expect(described_class.over([turn]).value).to eq({})
  end

  it "counts a summarizer's answer once, by its payment and not by the oracle answer beside it" do
    answer = Lain::Telemetry::OracleAnswer.new(oracle_digest: "blake3:oracle", question: "summarise",
                                               answer: { "summary" => "..." }, model: "m",
                                               usage: { input_tokens: 9, output_tokens: 1 }, wall_clock: 1.0)

    folded = described_class.over([paid.call(9, 1, requester: :summarizer), answer])

    expect(folded.value).to eq([nil, "summarizer"] => Lain::Usage.new(input_tokens: 9, output_tokens: 1))
  end

  it "combines 2 halves into the whole" do
    left = described_class.over([paid.call(10, 1, command: "plan")])
    right = described_class.over([paid.call(5, 2, command: "plan"), paid.call(1, 1)])

    expect(left.combine(right)).to eq(described_class.over([paid.call(10, 1, command: "plan"),
                                                            paid.call(5, 2, command: "plan"), paid.call(1, 1)]))
  end

  it "answers itself for a record it does not count" do
    folded = described_class.over([paid.call(10, 1)])

    expect(folded.step(turn)).to be(folded)
  end
end
