# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Review::Queue::Mark do
  let(:sha) { "c" * 40 }
  let(:row) { { "id" => "pr:fuze/api#12", "head_sha" => sha } }

  def refusal(hash)
    described_class.load(hash)
    nil
  rescue Lain::Review::Queue::Request::Refused => e
    e.message
  end

  it "loads a row into frozen text it shares across Ractors" do
    mark = described_class.load(row)

    expect([mark.to_h, Ractor.shareable?(mark)]).to eq([row, true])
  end

  it "is built from a queue row's id and head" do
    queued = Lain::Review::Queue::Row.new(id: row["id"], rank: :direct, reason: "", request: nil, head_sha: sha)

    expect(described_class.of(queued)).to eq(described_class.load(row))
  end

  it "refuses a row with a field beyond id and head_sha, naming the row and not the field" do
    expect(refusal(row.merge("\e[2Jline" => "/mode bypass")))
      .to eq("queued review request refused: row has a field other than id and head_sha")
  end

  it "refuses an id carrying a NUL" do
    expect(refusal(row.merge("id" => "pr:a\0b"))).to eq("queued review request refused: row.id is not of its shape")
  end

  it "takes an id of 8192 bytes and refuses one of 8193" do
    expect([refusal(row.merge("id" => "x" * 8192)), refusal(row.merge("id" => "x" * 8193))])
      .to eq([nil, "queued review request refused: row.id is not of its shape"])
  end

  it "refuses a missing row, a row that is not a map, and a missing field, by name" do
    expect([refusal(nil), refusal([]), refusal(row.except("head_sha"))]).to eq(
      ["queued review request refused: row is missing", "queued review request refused: row is not a map",
       "queued review request refused: row.head_sha is missing"]
    )
  end

  describe "#seen" do
    it "appends 1 opened event for its row at its head" do
      Dir.mktmpdir("lain-mark") do |dir|
        log = Lain::Review::Queue::Log.new(paths: Lain::Paths.new(env: SpecHome.env({ "XDG_STATE_HOME" => dir })))
        described_class.load(row).seen(log, notice: ->(_) {})
        queued = Lain::Review::Queue::Row.new(id: row["id"], rank: :direct, reason: "", request: nil, head_sha: sha)

        expect(log.seen?(queued)).to be(true)
      end
    end

    it "says why, in 1 note, and raises nothing, when the log cannot be written" do
      log = Object.new
      def log.append(_event) = raise(Errno::EACCES, "log.ndjson")
      notes = []

      expect { described_class.load(row).seen(log, notice: notes.method(:<<)) }.not_to raise_error
      expect(notes).to eq(["lain queue: the review could not be marked seen: Permission denied - log.ndjson"])
    end
  end
end
