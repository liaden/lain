# frozen_string_literal: true

require "tmpdir"
require "json"

# Two objects now total the same money, and this is the seam that keeps them
# from disagreeing about it.
#
# {Lain::Agent::Accounting} sums `Response#usage` as the run's ledger;
# {Lain::StatusFeed} sums `Telemetry::TurnUsage` for the HUD. They are fed by
# ONE call -- `Accounting#observe` rolls the response into `#usage` and journals
# the record in the same breath -- so the parity below is structural rather than
# coincidental, and this spec is what says so out loud. Without it, the chunk
# that closed F76 (two surfaces disagreeing about the inbox count) would have
# recreated F76 for the token count.
#
# The subtle half is regeneration. `Usage`'s own doc says correct aggregation
# sums over UNIQUE turn digests -- but that rule is about content reachable from
# a branched head, and {Telemetry::TurnUsage}'s doc is explicit that its digest
# is a join key and NOT unique across records: rewind, regenerate, and two
# records land under one digest, both genuinely paid for. So the feed must
# double-count exactly where Accounting does, and the second example is the pin.
RSpec.describe "StatusFeed x Agent::Accounting token parity", :seam do
  around do |example|
    Dir.mktmpdir("usage-parity-spec") { |dir| @dir = dir and example.run }
  end

  def path = File.join(@dir, "state.json")
  def published = JSON.parse(File.read(path))

  def usage(input:, output:, cache_read: 0, cache_creation: 0)
    Lain::Usage.new(input_tokens: input, output_tokens: output,
                    cache_read_input_tokens: cache_read, cache_creation_input_tokens: cache_creation)
  end

  # A landed oracle answer, exactly as Oracle::Recorded::Journaling writes one:
  # it names the model that answered and carries that call's usage, but nothing
  # about why a turn stopped -- which is the distinction the feed dispatches on.
  def oracle_answer(spend)
    Lain::Telemetry::OracleAnswer.new(
      oracle_digest: "blake3:oracle", question: "summarise", answer: { "text" => "..." },
      model: "claude-haiku", usage: spend.to_h, wall_clock: 1.5
    )
  end

  # A real StatusFeed IS the run's journal here: it answers `#<<` like any other
  # leg of the CLI::JournalTee it rides in a live chat, so the Agent needs no
  # accommodation to feed it.
  let(:feed) { Lain::StatusFeed.new(path:) }

  it "publishes exactly what the run's own Accounting totals, over a real multi-turn Agent" do
    agent, = record_run(
      [tool_response(["tu_1", "echo", { "text" => "hi" }], model: "claude-x",
                                                           usage: usage(input: 900, output: 120, cache_read: 40)),
       text_response("done", model: "claude-x",
                             usage: usage(input: 1_400, output: 60, cache_creation: 300))],
      toolset: Lain::Toolset.new([EchoTool.new]),
      context: Lain::Context.new(model: "claude-x", max_tokens: 1024),
      journal: feed, prompt: "echo hi"
    )

    expect(agent.usage.total_tokens).to eq(2_820)
    expect(published["run_tokens"]).to eq(agent.usage.total_tokens)
  end

  # The regeneration case, driven through the real Accounting rather than a
  # rewind: `#observe` is the ONE place both totals are fed, so calling it twice
  # under one digest is exactly what a regenerated turn does to each of them.
  it "double-counts a regenerated turn on BOTH sides, so one digest paid twice still agrees" do
    accounting = Lain::Agent::Accounting.new(journal: feed)
    response = Lain::Response.new(content: [{ "type" => "text", "text" => "same" }], stop_reason: :end_turn,
                                  model: "claude-x", usage: usage(input: 500, output: 25, cache_read: 75))

    2.times { accounting.observe(response, digest: "blake3:regenerated") }

    expect(accounting.usage.total_tokens).to eq(1_200)
    expect(published["run_tokens"]).to eq(accounting.usage.total_tokens)
  end

  # The falsification, and the reason `#usage` ALONE is not the duck.
  # Telemetry::OracleAnswer answers `#usage` too and rides this same tee on the
  # default-on compaction route, so a feed dispatching on `#usage` summed every
  # oracle call into a total whose whole contract is equality with
  # Accounting#usage -- measured at HUD 10,320 against Accounting 1,020 after
  # ONE eager summary. The examples above cannot catch it: they drive Agent
  # turns, and every record an Agent turn produces is a TurnUsage.
  #
  # Oracle spend is real money and is deliberately not counted here. A second,
  # differently scoped figure is a separate field for a separate card; adding it
  # silently to this one is what breaks the parity this file exists to hold.
  it "does not count an oracle answer, whose spend Accounting does not carry either" do
    accounting = Lain::Agent::Accounting.new(journal: feed)
    accounting.observe(
      Lain::Response.new(content: [{ "type" => "text", "text" => "hi" }], stop_reason: :end_turn,
                         model: "claude-x", usage: usage(input: 1_000, output: 20)),
      digest: "blake3:turn-one"
    )

    feed << oracle_answer(usage(input: 9_000, output: 300))

    expect(published["run_tokens"]).to eq(1_020)
    expect(published["run_tokens"]).to eq(accounting.usage.total_tokens)
  end

  # The same predicate repairs a defect that PRE-DATES this card: an oracle
  # answer names a model and carries no cache fields, so `occupancy_of` ran on
  # it and republished the ORACLE's prompt measured against the chat's window.
  # Reproduced live before the fix: 0.005 -> 0.045 on one oracle answer.
  it "does not let an oracle answer republish the chat's context occupancy" do
    feed << Lain::Telemetry::TurnUsage.new(
      digest: "blake3:turn-one", model: "claude-x", stop_reason: :end_turn,
      usage: usage(input: 1_000, output: 20).to_h.transform_keys(&:to_s)
    )
    after_turn = published["occupancy"]

    feed << oracle_answer(usage(input: 9_000, output: 300))

    expect(published["occupancy"]).to eq(after_turn)
  end

  # The HUD figure is a spend counter for THIS process against THIS key, and
  # every token the provider billed belongs in it -- cached reads included,
  # since a cached read is cheaper, not free. `Usage#total_tokens` is that
  # definition, and this holds the published number to it field by field.
  it "counts every billed field, cache reads and cache writes included" do
    accounting = Lain::Agent::Accounting.new(journal: feed)
    billed = usage(input: 1, output: 2, cache_read: 4, cache_creation: 8)

    accounting.observe(
      Lain::Response.new(content: [{ "type" => "text", "text" => "x" }], stop_reason: :end_turn,
                         model: "claude-x", usage: billed),
      digest: "blake3:one"
    )

    expect(published["run_tokens"]).to eq(15)
    expect(published["run_tokens"]).to eq(billed.total_tokens)
  end
end
