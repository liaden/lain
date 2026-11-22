# frozen_string_literal: true

RSpec.describe Lain::Frontend::Intake::HeldLines do
  subject(:held) { described_class.new(clock: -> { 7.0 }) }

  it "gives lines back oldest first, once each" do
    held.keep("one")
    held.keep("two", kind: :you)

    expect([held.take, held.texts, held.take, held.take]).to eq(["one", ["two"], "two", nil])
  end

  it "records the prompt kind and the time each line was kept" do
    held.keep("later", kind: :approval)

    expect(held.entries.map { [_1.text, _1.kind, _1.at] }).to eq([["later", :approval, 7.0]])
  end

  it "ages an entry by the same clock that stamped it" do
    now = [7.0]
    aging = described_class.new(clock: -> { now.first })
    aging.keep("later")
    now[0] = 12.5

    expect(aging.entries.map(&:age)).to eq([5.5])
  end

  it "empties on clear, answering the texts dropped" do
    held.keep("a")
    held.keep("b")

    expect([held.clear, held.texts]).to eq([%w[a b], []])
  end

  describe "#expire" do
    it "drops the words typed at the named read, and keeps its commands and every other read's lines" do
      held.keep("network", read: 3)
      held.keep("/goal off", read: 3)
      held.keep("elsewhere", read: 4)
      held.keep("typeahead")

      expect([held.expire(3).map(&:text), held.texts]).to eq([["network"], ["/goal off", "elsewhere", "typeahead"]])
    end
  end

  it "says how many were dropped in the singular and the plural" do
    expect([described_class.dropped(1),
            described_class.dropped(2)]).to eq(["dropped 1 held line", "dropped 2 held lines"])
  end
end
