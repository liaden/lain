# frozen_string_literal: true

RSpec.describe Lain::Review::Hunk do
  # The ordinary modification hunk: context, a deletion, an addition, context.
  # Every scenario states only the field it moves.
  def hunk(path: "lib/lain/agent.rb", old_start: 10, old_count: 3, new_start: 10, new_count: 3,
           heading: "def call",
           lines: ["   @store = store", "-  audit!(input)", "+  audit!(validated)", "   run!"])
    described_class.new(path:, old_start:, old_count:, new_start:, new_count:, heading:, lines:)
  end

  # The key of a hunk that is the ONLY one in its file. Never the shape a caller
  # should use for a real changeset -- see ".keys is batch-scoped" below.
  def sole_key_of(hunk) = described_class.keys([hunk]).first

  def digest_of(key) = key.split(":").last

  it "is deeply frozen" do
    expect(hunk).to be_deeply_frozen
  end

  it "refuses a missing path or line loudly rather than hashing it as empty" do
    expect { hunk(path: nil) }.to raise_error(NoMethodError, /to_str/)
    expect { hunk(lines: ["+x", nil]) }.to raise_error(NoMethodError, /to_str/)
    expect { hunk(old_start: "ten") }.to raise_error(ArgumentError, /Integer/)
  end

  describe "the key ignores position" do
    it "is unchanged when 500 lines are inserted above it and the header renumbers" do
      expect(sole_key_of(hunk(new_start: 510))).to eq(sole_key_of(hunk))
    end

    it "is unchanged when every number in the @@ header moves" do
      expect(sole_key_of(hunk(old_start: 610, old_count: 9, new_start: 510, new_count: 9))).to eq(sole_key_of(hunk))
    end

    it "is unchanged when git's function-context heading changes" do
      expect(sole_key_of(hunk(heading: "def call_with_audit"))).to eq(sole_key_of(hunk))
    end
  end

  describe "the key follows the hunk's own text" do
    it "changes when the body changes" do
      expect(sole_key_of(hunk(lines: ["+  audit!(input)"])))
        .not_to eq(sole_key_of(hunk(lines: ["+  audit!(validated)"])))
    end

    it "keeps origin markers, so adding a line and deleting it are different hunks" do
      expect(sole_key_of(hunk(lines: ["+  audit!(input)"]))).not_to eq(sole_key_of(hunk(lines: ["-  audit!(input)"])))
    end

    it "keeps whitespace, so a re-indented line is a different hunk" do
      expect(sole_key_of(hunk(lines: ["+  audit!(input)"]))).not_to eq(sole_key_of(hunk(lines: ["+    audit!(input)"])))
    end

    it "keeps line order" do
      expect(sole_key_of(hunk(lines: ["+a", "+b"]))).not_to eq(sole_key_of(hunk(lines: ["+b", "+a"])))
    end

    it "separates lines by a byte no diff line carries, so two lines cannot read as one" do
      pair = sole_key_of(hunk(lines: ["+a", " b"]))

      expect(pair).not_to eq(sole_key_of(hunk(lines: ["+a b"])))
      expect(pair).not_to eq(sole_key_of(hunk(lines: ["+a  b"])))
    end
  end

  describe "encoding" do
    def binary(text) = (+text).force_encoding(Encoding::BINARY)

    it "addresses non-UTF-8 bytes rather than raising" do
      expect(sole_key_of(hunk(lines: [binary("+\xff\x00\xfe")]))).to start_with("hunk-content-v1:")
    end

    it "addresses a body whose lines disagree about their encoding" do
      expect(sole_key_of(hunk(lines: ["+café", binary("+\xff")]))).to start_with("hunk-content-v1:")
    end

    it "addresses a non-ASCII path beside a binary body" do
      expect(sole_key_of(hunk(path: "lib/café.rb", lines: [binary("+\xff")]))).to start_with("hunk-content-v1:")
    end
  end

  describe "the key is scoped to one file" do
    it "gives byte-identical hunks in two files two distinct content keys" do
      keys = described_class.keys([hunk(path: "a.rb"), hunk(path: "b.rb")])

      expect(keys.uniq.size).to eq(2)
      expect(keys).to all(start_with("hunk-content-v1:"))
    end

    it "frames the path by length, so a newline in a path cannot collide with a body line" do
      expect(sole_key_of(hunk(path: "a\nb", lines: ["+x"]))).not_to eq(sole_key_of(hunk(path: "a", lines: ["b", "+x"])))
    end
  end

  describe "duplicate hunks in one file" do
    let(:first) { hunk(old_start: 10, new_start: 10) }
    let(:second) { hunk(old_start: 90, new_start: 90) }

    it "gets distinct keys, both span-qualified" do
      keys = described_class.keys([first, second])

      expect(keys.uniq.size).to eq(2)
      expect(keys).to all(start_with("hunk-span-v1:"))
    end

    it "leaves every other hunk in the file on its content key" do
      other = hunk(old_start: 200, new_start: 200, lines: ["+  audit!(nothing)"])

      expect(described_class.keys([first, second, other]).last).to eq(sole_key_of(other))
    end

    it "survives an author's insertion above it, which moves only the new side" do
      moved = described_class.keys([first.with(new_start: 510), second.with(new_start: 590)])

      expect(moved).to eq(described_class.keys([first, second]))
    end

    it "moves when the base moves under it, which moves the old side" do
      moved = described_class.keys([first, second.with(old_start: 63, new_start: 63)])

      expect(moved.last).not_to eq(described_class.keys([first, second]).last)
    end

    it "falls back to the full span when two duplicates tie on their old-side span" do
      tied = second.with(old_start: first.old_start, old_count: first.old_count)
      keys = described_class.keys([first, tied])

      expect(keys.uniq.size).to eq(2)
      expect(keys).to all(start_with("hunk-span-v1:"))
    end

    it "returns the survivor to its content key when one duplicate changes" do
      keys = described_class.keys([first, second.with(lines: ["+  audit!(nothing)"])])

      expect(keys).to all(start_with("hunk-content-v1:"))
      expect(keys.first).to eq(sole_key_of(first))
    end

    it "carries the whole old-side span, count included" do
      expect(first.span_key).not_to eq(first.with(old_count: 30).span_key)
    end

    it "terminates the span, so a body of digits cannot read as part of it" do
      expect(hunk(old_start: 10, old_count: 3, lines: ["1+x"]).span_key)
        .not_to eq(hunk(old_start: 10, old_count: 31, lines: ["+x"]).span_key)
    end

    it "terminates the tie-breaking full span for the same reason" do
      expect(hunk(old_start: 10, old_count: 3, new_start: 20, new_count: 4, lines: ["1+x"]).full_span_key)
        .not_to eq(hunk(old_start: 10, old_count: 3, new_start: 20, new_count: 41, lines: ["+x"]).full_span_key)
    end
  end

  describe "the scheme version" do
    it "prefixes every key, over hex digest bytes" do
      keys = described_class.keys([hunk, hunk(old_start: 90, new_start: 90), hunk(path: "other.rb")])

      expect(keys).to all(match(/\A(?:hunk-content-v1|hunk-span-v1):\h{64}\z/))
    end

    it "distinguishes the two schemes by their digests, not only by their prefixes" do
      expect(digest_of(hunk.span_key)).not_to eq(digest_of(hunk.content_key))
    end

    # Grey-box on purpose. The scheme is TERMINATED in the hashed input, not
    # merely placed first, so no scheme can run into what follows it. With only
    # two schemes, neither a prefix of the other, no black-box pair can tell the
    # two framings apart -- the day a `hunk-content-v10` arrives is the day it
    # matters, and that is too late to discover the law was never pinned.
    it "terminates the scheme in the hashed input, so a longer scheme cannot swallow what follows" do
      expect(digest_of(hunk.send(:key, "x", "y"))).not_to eq(digest_of(hunk.send(:key, "xy")))
    end

    it "is hashed, so no body mimicking a span frame can forge a span digest" do
      target = hunk(path: "p.rb", old_start: 7, old_count: 2, lines: ["+x"])
      forged = hunk(path: "p.rb", lines: ["7,2", "+x"])

      expect(digest_of(forged.content_key)).not_to eq(digest_of(target.span_key))
    end
  end

  describe ".keys is batch-scoped" do
    it "answers one key per hunk, in the order given" do
      hunks = [hunk, hunk(path: "b.rb"), hunk(path: "c.rb")]

      expect(described_class.keys(hunks)).to eq(hunks.map { |one| sole_key_of(one) })
    end

    it "answers nothing for nothing" do
      expect(described_class.keys([])).to eq([])
    end

    it "answers a frozen array, so a mark set cannot be edited through it" do
      expect(described_class.keys([hunk])).to be_frozen
    end

    # The precondition, stated as the cost of breaking it: a hunk cannot tell on
    # its own that it is duplicated, so a caller keying one at a time hands two
    # different hunks ONE key -- reviewed state on unreviewed code.
    it "needs the whole changeset in one call, because a lone hunk cannot see its duplicate" do
      pair = [hunk(old_start: 10, new_start: 10), hunk(old_start: 90, new_start: 90)]

      expect(described_class.keys(pair).uniq.size).to eq(2)
      expect(pair.map { |one| sole_key_of(one) }.uniq.size).to eq(1)
    end
  end

  # Shareability does not imply usability: `Ext.blake3_hex` is not ractor-safe,
  # the same recorded gap `spec/lain/rust/fuzzy_spec.rb` pins for Fuzzy and Bm25.
  describe "Ractor usability" do
    it "is shareable, but its key can only be computed on the main Ractor" do
      subject = hunk

      expect(Ractor.shareable?(subject)).to be(true)
      expect { Ractor.new(subject, &:content_key).value }.to raise_error(Ractor::RemoteError)
    end
  end
end
