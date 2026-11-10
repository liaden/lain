# frozen_string_literal: true

require "json"

# A handback reuses the standing HEAD when nothing after the anchor's first read
# can have moved it; the fold counts that over journaled `handback` lines, whose
# values are strings where Retirement sees symbols.
RSpec.describe Lain::Bench::HandbackReuse do
  def handback(**fields)
    { "type" => "handback", "worker_key" => "w", "outcome" => "merged", "sync" => "current",
      "attempts" => [] }.merge(fields.transform_keys(&:to_s))
  end

  def fold(*records) = described_class.fold(records.map(&:to_json))

  it "reports how many of the handbacks reused the standing HEAD" do
    reuse = fold(handback, handback(sync: "disabled"), handback(checks: { "outcome" => "skipped", "attempts" => [] }),
                 handback(sync: "synced"))

    expect([reuse.reused, reuse.total]).to eq([3, 4])
  end

  it "counts a string checks outcome of passed as reused, as :passed is in Retirement" do
    reuse = fold(handback(checks: { "outcome" => "passed", "attempts" => [] }))

    expect(reuse.reused).to eq(1)
  end

  it "reads a string-keyed checks outcome outside the whitelist as a moved HEAD" do
    reuse = fold(handback(checks: { "outcome" => "failed", "attempts" => [] }))

    expect(reuse.reused).to eq(0)
  end

  it "counts a handback that ran a rebase attempt, or a fix attempt, as a moved HEAD" do
    reuse = fold(handback(attempts: [{ "n" => 1 }]),
                 handback(checks: { "outcome" => "fixed", "attempts" => [{ "n" => 1 }] }))

    expect([reuse.reused, reuse.total]).to eq([0, 2])
  end

  it "reads a record with no sync, as an epic-lane surrender writes it, as reused" do
    reuse = fold({ "type" => "handback", "worker_key" => "w", "outcome" => "merged" })

    expect(reuse.reused).to eq(1)
  end

  it "ignores every record that is not a handback, and reads an empty journal as 0 of 0" do
    expect(fold({ "type" => "turn" })).to have_attributes(reused: 0, total: 0)
  end

  it "answers a rate of nil when there were no handbacks" do
    expect([fold.rate, fold(handback).rate]).to eq([nil, 1.0])
  end
end
