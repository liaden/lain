# frozen_string_literal: true

RSpec.describe Lain::Chores::Item do
  it "reads an open line" do
    item = described_class.parse("- [ ] fix the thing\n")

    expect(item).to have_attributes(text: "fix the thing", tag: nil, state: :open, claim: nil)
  end

  it "reads a tag" do
    expect(described_class.parse("- [ ] [research] compare x and y\n"))
      .to have_attributes(text: "compare x and y", tag: "research")
  end

  it "reads done and failed lines" do
    expect([described_class.parse("- [x] done already").state, described_class.parse("- [!] broke <!-- no -->").state])
      .to eq(%i[done failed])
  end

  it "reads a claim comment" do
    item = described_class.parse("- [~] fix  <!-- lain pid=42 start=777 host=box since=2026-10-28T10:00:00Z -->")

    expect(item).to have_attributes(state: :claimed, text: "fix")
    expect(item.claim).to have_attributes(pid: 42, start: "777", host: "box", since: "2026-10-28T10:00:00Z")
  end

  it "is not an item for a line that is not a checkbox" do
    expect([described_class.parse("# Chores"), described_class.parse("- plain"), described_class.parse("")])
      .to eq([nil, nil, nil])
  end

  it "gives the same 12 hex id whatever the state, and different ids to different text" do
    open = described_class.parse("- [ ] fix the thing")
    claimed = described_class.parse("- [~] fix the thing  <!-- lain pid=1 start=2 host=h since=s -->")
    other = described_class.parse("- [ ] fix another thing")

    expect(open.id).to match(/\A\h{12}\z/)
    expect(other.id).not_to eq(open.id)
    expect(claimed.id).to eq(open.id)
  end

  describe "#line" do
    def self.items
      gen = PropCheck::Generators
      word = gen.alphanumeric_string(min: 1, max: 8)
      text = gen.array(word, min: 1, max: 4).map { |words| words.join(" ") }
      states = %i[open claimed done failed].map { |state| gen.constant(state) }
      gen.fixed_hash(text:, tag: gen.one_of(gen.constant(nil), word), state: gen.one_of(*states),
                     claim: claims(word))
         .map { |fields| described_class.new(id: nil, **fields, claim: (fields[:claim] if fields[:state] == :claimed)) }
    end

    def self.claims(word)
      gen = PropCheck::Generators
      start = gen.one_of(gen.positive_integer.map(&:to_s), gen.positive_integer.map { |n| "u#{n}" }, gen.constant("-"))
      gen.fixed_hash(pid: gen.positive_integer, start:, host: word, since: word)
         .map { |fields| Lain::Chores::Claim.new(**fields) }
    end

    include_examples "a round trip",
                     render: :line.to_proc,
                     parse: ->(line) { described_class.parse(line) },
                     equal: ->(parsed, item) { parsed == item.with(id: parsed.id) },
                     generator: items

    it "renders a claimed item as the claim line the file has always held" do
      claim = Lain::Chores::Claim.new(pid: 42, start: "777", host: "box", since: "2026-10-28T10:00:00Z")
      item = described_class.new(id: nil, text: "fix", tag: "research", state: :claimed, claim:)

      expect(item.line)
        .to eq("- [~] [research] fix  <!-- lain pid=42 start=777 host=box since=2026-10-28T10:00:00Z -->")
    end

    it "renders an open item bare and a finished one with the note it is given" do
      item = described_class.new(id: nil, text: "fix", tag: nil, state: :done, claim: nil)

      expect([item.with(state: :open).line, item.line(note: "landed abc")])
        .to eq(["- [ ] fix", "- [x] fix  <!-- landed abc -->"])
    end
  end
end
