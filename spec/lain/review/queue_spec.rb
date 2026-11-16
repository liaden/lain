# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Review::Queue do
  let(:dir) { Dir.mktmpdir }
  let(:paths) { Lain::Paths.new(env: { "HOME" => dir, "XDG_STATE_HOME" => dir }) }
  let(:log) { Lain::Review::Queue::Log.new(paths:) }

  after { FileUtils.remove_entry(dir) }

  def row(id, rank, head_sha: "C", reason: "because #{rank}")
    Lain::Review::Queue::Row.new(id:, rank:, reason:, request: :any, head_sha:)
  end

  def queue(*rows) = described_class.new(sources: [-> { rows }], log:)

  def opened(id, head_sha)
    Lain::Review::Queue::Log::Event.new(kind: :opened, at: Time.now, row_id: id, head_sha:)
  end

  it "keeps Row in its own file" do
    expect(Object.const_source_location("Lain::Review::Queue::Row").first).to end_with("review/queue/row.rb")
  end

  it "orders finished plan run, re-review, direct request, team request, path match, each with its reason" do
    shuffled = %i[path team direct re_review plan_run].map { |rank| row("pr:o/r##{rank}", rank) }

    expect(queue(*shuffled).map { |r| [r.rank, r.reason] })
      .to eq(%i[plan_run re_review direct team path].map { |rank| [rank, "because #{rank}"] })
  end

  it "merges rows from every source" do
    sources = [-> { [row("a", :team)] }, -> { [row("b", :plan_run)] }]

    expect(described_class.new(sources:, log:).map(&:id)).to eq(%w[b a])
  end

  it "keeps a source's own order inside a rank" do
    expect(queue(row("x", :direct), row("y", :direct), row("z", :direct)).map(&:id)).to eq(%w[x y z])
  end

  it "refuses a rank it does not know" do
    expect { queue(row("a", :bogus)).to_a }.to raise_error(KeyError)
  end

  it "hides a row opened at its head until the head moves" do
    log.append(opened("pr:o/r#12", "C"))

    expect([queue(row("pr:o/r#12", :direct, head_sha: "C")).map(&:id),
            queue(row("pr:o/r#12", :direct, head_sha: "D")).map(&:id)])
      .to eq([[], ["pr:o/r#12"]])
  end

  it "does not hide a row that was only notified" do
    log.append(Lain::Review::Queue::Log::Event.new(kind: :notified, at: nil, row_id: "a", head_sha: "C"))

    expect(queue(row("a", :direct)).map(&:id)).to eq(["a"])
  end
end
