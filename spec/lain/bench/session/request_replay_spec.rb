# frozen_string_literal: true

require "json"

RSpec.describe Lain::Bench::Session::RequestReplay do
  let(:read) { { "name" => "read_file", "description" => "reads a file", "input_schema" => { "type" => "object" } } }
  let(:bash) { { "name" => "bash", "description" => "runs a command", "input_schema" => { "type" => "object" } } }

  def said(count)
    Array.new(count) { |i| { "role" => "user", "content" => [{ "type" => "text", "text" => "m#{i}" }] } }
  end

  def recorded(messages:, tools: [read])
    sent = Lain::Request.new(model: "claude-opus-4-8", max_tokens: 1024, messages:, tools:)
    JSON.parse(JSON.generate(Lain::Telemetry::RequestSent.from(sent).to_journal))
  end

  it "rebuilds every recorded request to its recorded digest" do
    records = [recorded(messages: said(3)), recorded(messages: said(5))]

    expect(described_class.new(records:).baseline.map(&:digest)).to eq(records.map { |record| record["digest"] })
  end

  it "hashes only the messages past the first rebuilt request's in the second" do
    records = [recorded(messages: said(3)), recorded(messages: said(5))]

    # The first: its seed, 3 messages and the combine. The second: 2 messages and the combine.
    expect(digests_during { described_class.new(records:).baseline }).to eq(5 + 3)
  end

  it "survives a tool granted between 2 requests" do
    records = [recorded(messages: said(3)), recorded(messages: said(4), tools: [read, bash])]

    expect(described_class.new(records:).baseline.map(&:digest)).to eq(records.map { |record| record["digest"] })
  end

  it "rebuilds 2 requests differing only in 1 against 1.0 to their recorded digests" do
    records = [1, 1.0].map do |n|
      recorded(messages: [{ "role" => "assistant", "content" => [{ "type" => "tool_use", "input" => { "n" => n } }] }])
    end

    expect(described_class.new(records:).baseline.map(&:digest)).to eq(records.map { |record| record["digest"] })
  end

  it "refuses a payload that no longer rebuilds to its recorded digest" do
    forged = recorded(messages: said(2)).tap { |record| record["payload"]["max_tokens"] = 2048 }

    expect { described_class.new(records: [forged]).baseline }
      .to raise_error(Lain::Bench::Session::Corrupt, /rebuilds to/)
  end
end
