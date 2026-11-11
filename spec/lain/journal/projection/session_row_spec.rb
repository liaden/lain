# frozen_string_literal: true

RSpec.describe Lain::Journal::Projection::SessionRow do
  header = { "ts" => "2026-01-01T00:00:00.000000Z", "type" => "session", "format" => 4 }
  kept = { "ts" => header["ts"], "format" => 4 }
  turn = ->(digest) { { "ts" => "2026-01-01T00:00:01.000000Z", "type" => "turn", "digest" => digest } }
  rewound = ->(to, **more) { { "type" => "rewound", "from" => "x", "to" => to, **more } }
  closed = { "type" => "session_closed", "head" => "c", "reason" => "exit" }

  def fold(records) = described_class.over(records)

  describe "the chain" do
    it "holds the turns in the order they landed" do
      expect(fold([header, turn.call("a"), turn.call("b")]).chain).to eq(%w[a b])
    end

    it "keeps the digests up to a rewind's target, and none for a rewind to nothing" do
      records = [header, turn.call("a"), turn.call("b"), turn.call("c")]

      expect([fold([*records, rewound.call("b")]).chain, fold([*records, rewound.call(nil)]).chain])
        .to eq([%w[a b], []])
    end

    it "empties the chain for a target this file never recorded" do
      expect(fold([header, turn.call("a"), rewound.call("elsewhere")]).chain).to eq([])
    end

    it "ignores a retreat whose landing turn never arrives" do
      records = [header, turn.call("a"), turn.call("b"), rewound.call("a", "then" => "z")]

      expect(fold(records).chain).to eq(%w[a b])
    end

    it "applies a retreat once its landing turn follows" do
      records = [header, turn.call("a"), turn.call("b"), rewound.call("a", "then" => "z"), turn.call("z")]

      expect(fold(records).chain).to eq(%w[a z])
    end
  end

  describe "the head" do
    it "is the last turn's digest" do
      expect(fold([header, turn.call("a"), turn.call("b")]).head).to eq("b")
    end

    it "is a rewind's target, and nothing for a rewind to nothing" do
      records = [header, turn.call("a"), turn.call("b")]

      expect([fold([*records, rewound.call("a")]).head, fold([*records, rewound.call(nil)]).head]).to eq(["a", nil])
    end

    it "falls back to the close's anchor, then the chained-from head, when no turn moved it" do
      chained = header.merge("resumed_from" => { "head" => "from" })

      expect([fold([header, closed]).head, fold([chained]).head, fold([header]).head]).to eq(["c", "from", nil])
    end
  end

  describe "the file's own records" do
    it "reads the header, the close and the first record's type" do
      folded = fold([header, turn.call("a"), closed])

      expect([folded.header, folded.closed, folded.first_type, folded.size])
        .to eq([kept, { "head" => "c" }, "session", 3])
    end

    it "keeps the first header and the first close" do
      later = header.merge("ts" => "later")

      expect(fold([header, later, closed, closed.merge("head" => "d")]).then { [_1.header, _1.closed] })
        .to eq([kept, { "head" => "c" }])
    end

    it "answers nothing for a file with no records" do
      folded = fold([])

      expect([folded.header, folded.closed, folded.first_type, folded.size]).to eq([nil, nil, nil, 0])
    end
  end

  describe "the reentry note" do
    note = ->(text) { { "type" => "reentry_note", "note" => text } }

    it "is the latest note, and empty when none was recorded or the last one retracts" do
      expect([fold([header, note.call("a"), note.call("b")]).note, fold([header]).note,
              fold([header, note.call("a"), note.call("")]).note]).to eq(["b", "", ""])
    end
  end

  describe "a note followed by more turns" do
    it "keeps the note" do
      records = [header, { "type" => "reentry_note", "note" => "a" }, turn.call("x"), turn.call("y")]

      expect(fold(records).note).to eq("a")
    end
  end

  describe "the laws of a projection" do
    it "leaves the receiver as it was when stepped, both shareable" do
      before = fold([header, turn.call("a")])
      after = before.step(turn.call("b"))

      expect([Ractor.shareable?(before), Ractor.shareable?(after), before.chain, after.chain])
        .to eq([true, true, %w[a], %w[a b]])
    end

    it "folds a continuation as it folds the whole" do
      records = [header, turn.call("a"), turn.call("b"), closed]

      expect(fold(records.first(2)).over(records.last(2))).to eq(fold(records))
    end
  end
end
