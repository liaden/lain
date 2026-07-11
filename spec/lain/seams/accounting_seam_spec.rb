# frozen_string_literal: true

require "bigdecimal"
require "stringio"

require "lain/agent"
require "lain/compare"
require "lain/context"
require "lain/journal"
require "lain/ledger"
require "lain/provider/mock"
require "lain/response"
require "lain/toolset"
require "lain/usage"

# The seam the bench stands on: Agent -> Journal -> Ledger -> Compare, over real
# collaborators end to end. The Agent journals one Event::TurnUsage per model
# call; the Journal reduces it to NDJSON bytes; the Ledger reconstructs priced
# totals from THOSE BYTES ALONE (io.string, never the in-memory events); Compare
# reads the difference between two runs. The invariant under test is that the
# journal bytes are a sufficient record.
RSpec.describe "Agent x Journal x Ledger x Compare accounting seam" do
  # The bare family key from PriceBook::DEFAULTS, so pricing the mocked runs
  # depends on an exact lookup, not on family matching surviving.
  def model = "sonnet"

  def scripted_response(reply, usage)
    Lain::Response.new(content: [{ "type" => "text", "text" => reply }],
                       stop_reason: :end_turn, model: model, usage: usage)
  end

  def run_arm(reply:, usage:)
    io = StringIO.new
    agent = Lain::Agent.new(
      provider: Lain::Provider::Mock.new(responses: [scripted_response(reply, usage)]),
      toolset: Lain::Toolset.new,
      context: Lain::Context.new(model: model, max_tokens: 1024),
      journal: Lain::Journal.new(io: io)
    )
    agent.ask("measure me")
    { agent: agent, io: io }
  end

  let(:brief) do
    run_arm(reply: "ok", usage: Lain::Usage.new(input_tokens: 120, output_tokens: 30))
  end
  let(:verbose) do
    run_arm(reply: "a much longer answer " * 8,
            usage: Lain::Usage.new(input_tokens: 900, output_tokens: 700))
  end

  def timeline_of(arm) = arm.fetch(:agent).timeline
  def bytes_of(arm) = arm.fetch(:io).string

  # THE point of the seam: the Ledger is built from the journal's raw NDJSON
  # bytes, not from the event objects the Agent happened to hold in memory.
  def ledger_from_bytes(arm)
    Lain::Ledger.from_journal(bytes_of(arm).each_line)
  end

  def run_from(name, arm)
    Lain::Compare::Run.from_timeline(name: name, timeline: timeline_of(arm),
                                     ledger: ledger_from_bytes(arm))
  end

  # Exact, not merely distinct-and-positive: a usage field silently dropped in
  # serialization would rebuild as zero and could still pass the distribution
  # checks below. Cost deliberately stays at distinct-and-positive -- asserting
  # exact dollars would couple the seam to PriceBook's rates.
  it "rebuilds the arranged usage exactly from the journal bytes" do
    expect(ledger_from_bytes(brief).usage(timeline_of(brief)))
      .to eq(Lain::Usage.new(input_tokens: 120, output_tokens: 30))
    expect(ledger_from_bytes(verbose).usage(timeline_of(verbose)))
      .to eq(Lain::Usage.new(input_tokens: 900, output_tokens: 700))
  end

  it "compares two runs priced entirely from their journal bytes" do
    compare = Lain::Compare.new([run_from("brief", brief), run_from("verbose", verbose)])

    tokens = compare.distribution(:total_tokens).values
    expect(tokens).to all(be_positive)
    expect(tokens.uniq.size).to eq(2)

    costs = compare.distribution(:cost).values
    expect(costs).to all(be_a(BigDecimal).and(be_positive))
    expect(costs.uniq.size).to eq(2)

    report = compare.report
    expect(report).to include("brief", "verbose", "total tokens", "cost (USD)")
  end
end
