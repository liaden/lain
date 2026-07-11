# frozen_string_literal: true

require "json"
require "stringio"

require "lain/agent/accounting"

require "lain/journal"
require "lain/response"
require "lain/usage"

RSpec.describe Lain::Agent::Accounting do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  def records
    journal_io.string.each_line.map { |line| JSON.parse(line) }
  end

  def response(input: 10, output: 5, model: "claude-opus-4-8", stop_reason: :end_turn)
    Lain::Response.new(
      content: [{ "type" => "text", "text" => "hi" }],
      stop_reason: stop_reason, model: model,
      usage: Lain::Usage.new(input_tokens: input, output_tokens: output)
    )
  end

  it "starts at Usage.zero" do
    expect(described_class.new.usage).to eq(Lain::Usage.zero)
  end

  describe "#observe" do
    it "accumulates the Usage monoid and returns the cumulative total" do
      accounting = described_class.new

      first = accounting.observe(response(input: 10, output: 5), digest: "blake3:one")
      expect(first).to eq(Lain::Usage.new(input_tokens: 10, output_tokens: 5))

      second = accounting.observe(response(input: 3, output: 2), digest: "blake3:two")
      expect(second).to eq(Lain::Usage.new(input_tokens: 13, output_tokens: 7))
      expect(accounting.usage).to eq(second)
    end

    it "journals one turn_usage record per observation, keyed by the committed turn's digest" do
      accounting = described_class.new(journal: journal)
      accounting.observe(response, digest: "blake3:one")
      accounting.observe(response(input: 3, output: 2), digest: "blake3:two")

      expect(records.map { |record| record["type"] }).to eq(%w[turn_usage turn_usage])
      expect(records.map { |record| record["digest"] }).to eq(%w[blake3:one blake3:two])
      expect(records.first).to include(
        "model" => "claude-opus-4-8", "stop_reason" => "end_turn",
        "usage" => { "input_tokens" => 10, "output_tokens" => 5,
                     "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => 0 }
      )
    end

    it "records each turn's OWN usage, not the running total" do
      accounting = described_class.new(journal: journal)
      accounting.observe(response(input: 10, output: 5), digest: "blake3:one")
      accounting.observe(response(input: 3, output: 2), digest: "blake3:two")

      expect(records.last["usage"]).to include("input_tokens" => 3, "output_tokens" => 2)
    end

    it "needs no journal: the default Null channel absorbs the record" do
      accounting = described_class.new
      expect { accounting.observe(response, digest: "blake3:one") }.not_to raise_error
      expect(accounting.usage.total_tokens).to eq(15)
    end

    it "tolerates a response with no model, as a bare mock produces" do
      accounting = described_class.new(journal: journal)
      accounting.observe(response(model: nil), digest: "blake3:one")

      expect(records.first).to include("type" => "turn_usage", "model" => nil)
    end
  end
end
