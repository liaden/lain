# frozen_string_literal: true

require "json"
require "stringio"

# B1: the pin-set -- turn digests an operator (or a later auto-pin) marked as
# "compaction must not elide this". It mirrors the READ-set end to end, not the
# write-set: only the read-set is journaled and replayed, so a pin that mirrored
# the write-set would silently vanish on --resume.
RSpec.describe Lain::Session do
  subject(:session) { described_class.new }

  let(:digest) { "blake3:aaaa1111" }
  let(:other) { "blake3:bbbb2222" }

  describe "the pin-set" do
    # AC1: a pinned digest is remembered and reported.
    it "records a pin and answers pinned? true for it, false for digests never pinned" do
      session.record_pin(digest)

      expect(session.pinned?(digest)).to be(true)
      expect(session.pinned?(other)).to be(false)
      expect(session.pins).to include(digest)
    end

    # AC2: unpinning removes it.
    it "forgets a digest that is unpinned" do
      session.record_pin(digest)
      session.record_unpin(digest)

      expect(session.pinned?(digest)).to be(false)
      expect(session.pins).to be_empty
    end

    it "answers a sorted, frozen list so a consumer cannot vary with pin order" do
      session.record_pin(other)
      session.record_pin(digest)

      expect(session.pins).to eq([digest, other].sort).and be_frozen
    end

    it "is idempotent: pinning twice keeps one entry, unpinning what was never pinned is a no-op" do
      session.record_pin(digest)
      session.record_pin(digest)
      session.record_unpin(other)

      expect(session.pins).to eq([digest])
    end

    it "returns self so a caller can chain, like record_read" do
      expect(session.record_pin(digest)).to be(session)
      expect(session.record_unpin(digest)).to be(session)
    end

    # Fix 2: a digest is a content address, and there is no sensible
    # empty-string one. `-nil.to_s` used to slip "" into the set, after which
    # `pinned?(nil)` answered TRUE -- a pin the operator never took, protecting
    # a turn that does not exist.
    describe "a blank digest" do
      it "refuses a nil pin loudly rather than pinning the empty string" do
        expect { session.record_pin(nil) }.to raise_error(ArgumentError, /must name a turn digest/)
        expect(session.pins).to eq([])
      end

      it "refuses an empty and a whitespace-only digest the same way" do
        expect { session.record_pin("") }.to raise_error(ArgumentError, /must name a turn digest/)
        expect { session.record_pin("   ") }.to raise_error(ArgumentError, /must name a turn digest/)
      end

      it "refuses a blank unpin too -- the retraction half must not be laxer than the write" do
        expect { session.record_unpin(nil) }.to raise_error(ArgumentError, /must name a turn digest/)
      end

      # Falls out of the write guard: nothing blank can ever enter the set, so
      # the query needs no guard of its own and stays raise-free for callers.
      it "answers pinned? false for a blank digest without raising" do
        session.record_pin(digest)

        expect(session.pinned?(nil)).to be(false)
        expect(session.pinned?("")).to be(false)
      end
    end
  end

  # AC3: the Null session answers honestly rather than raising -- the same duck,
  # so no caller writes `if session`.
  describe Lain::Session::Null do
    subject(:null) { described_class.instance }

    it "answers pinned? false and offers no pins" do
      null.record_pin("blake3:aaaa1111")

      expect(null.pinned?("blake3:aaaa1111")).to be(false)
      expect(null.pins).to eq([])
      expect(null.record_unpin("blake3:aaaa1111")).to be(null)
    end
  end
end

# AC4: a pin is journaled with the digest it names -- the Session::Journaled
# decorator's job, so Session itself stays journal-ignorant.
RSpec.describe Lain::Session::Journaled do
  subject(:journaled) { described_class.new(session:, journal:) }

  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:session) { Lain::Session.new }

  def records = journal_io.string.each_line.map { |line| JSON.parse(line) }
  def of_type(type) = records.select { |record| record["type"] == type }

  it "journals a session_pin naming the digest, and forwards to the wrapped session" do
    journaled.record_pin("blake3:aaaa1111")

    expect(session.pinned?("blake3:aaaa1111")).to be(true)
    expect(journaled.pinned?("blake3:aaaa1111")).to be(true)
    expect(of_type("session_pin"))
      .to contain_exactly(a_hash_including("digest" => "blake3:aaaa1111", "pinned" => true))
  end

  # The record stream is an ordered LOG, not a set of pin events: a retraction
  # has to be expressible, or a pin-then-unpin would rebuild as pinned.
  it "journals an unpin as the same record type carrying pinned false" do
    journaled.record_pin("blake3:aaaa1111")
    journaled.record_unpin("blake3:aaaa1111")

    expect(session.pinned?("blake3:aaaa1111")).to be(false)
    expect(of_type("session_pin").map { |record| record["pinned"] }).to eq([true, false])
  end

  it "forwards pins unchanged" do
    journaled.record_pin("blake3:aaaa1111")

    expect(journaled.pins).to eq(["blake3:aaaa1111"])
  end
end

# AC5/AC6: pins survive a resume, and a session that never pinned replays clean.
RSpec.describe Lain::SessionRecord::Replay do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:journaled) { Lain::Session::Journaled.new(session: Lain::Session.new, journal:) }

  def replayed = described_class.new(journal_io.string.each_line).session

  it "rebuilds a pin, and a pin that was later retracted rebuilds as not pinned" do
    journaled.record_pin("blake3:aaaa1111")
    journaled.record_pin("blake3:bbbb2222")
    journaled.record_unpin("blake3:bbbb2222")

    fresh = replayed

    expect(fresh.pinned?("blake3:aaaa1111")).to be(true)
    expect(fresh.pinned?("blake3:bbbb2222")).to be(false)
    expect(fresh.pins).to eq(["blake3:aaaa1111"])
  end

  it "replays a re-pin after an unpin as pinned -- the log is folded in recorded order" do
    journaled.record_pin("blake3:aaaa1111")
    journaled.record_unpin("blake3:aaaa1111")
    journaled.record_pin("blake3:aaaa1111")

    expect(replayed.pinned?("blake3:aaaa1111")).to be(true)
  end

  it "rebuilds a pin-free session with no pins and raises nothing" do
    journaled.record_read("/tmp/a.rb")

    fresh = nil
    expect { fresh = replayed }.not_to raise_error
    expect(fresh.pins).to eq([])
  end

  # Fix 5, promoted from probe-pin-replay.rb: nothing else would catch a
  # regression to a SET-shaped fold, which is the one shape this record type
  # exists to rule out.
  describe "the fold is genuinely order-sensitive (probes-become-specs)" do
    it "flips its answer when the pin lines are reversed -- a set fold could not" do
      journaled.record_pin("blake3:aaaa1111")
      journaled.record_unpin("blake3:aaaa1111")
      lines = journal_io.string.each_line.to_a
      pin_lines = lines.select { |line| JSON.parse(line)["type"] == "session_pin" }
      reversed = (lines - pin_lines) + pin_lines.reverse

      expect(described_class.new(lines).session.pinned?("blake3:aaaa1111")).to be(false)
      expect(described_class.new(reversed).session.pinned?("blake3:aaaa1111")).to be(true)
    end

    it "folds interleaved digests independently, with no cross-talk" do
      journaled.record_pin("blake3:aaaa1111")
      journaled.record_pin("blake3:bbbb2222")
      journaled.record_unpin("blake3:aaaa1111")
      journaled.record_pin("blake3:cccc3333")
      journaled.record_unpin("blake3:bbbb2222")
      journaled.record_pin("blake3:aaaa1111")

      expect(replayed.pins).to eq(["blake3:aaaa1111", "blake3:cccc3333"])
    end

    it "is undisturbed by other record types written between the pins" do
      journaled.record_pin("blake3:aaaa1111")
      journaled.record_read("/tmp/x.rb")
      journaled.write_todos([Struct.new(:content, :status).new("t", "pending")])
      journaled.record_unpin("blake3:aaaa1111")
      journaled.record_read("/tmp/y.rb")
      journaled.record_pin("blake3:bbbb2222")

      fresh = replayed

      expect(fresh.pinned?("blake3:aaaa1111")).to be(false)
      expect(fresh.pinned?("blake3:bbbb2222")).to be(true)
      expect(fresh.read?("/tmp/x.rb")).to be(true)
    end

    it "does not refcount: two pins then one unpin ends NOT pinned" do
      journaled.record_pin("blake3:aaaa1111")
      journaled.record_pin("blake3:aaaa1111")
      journaled.record_unpin("blake3:aaaa1111")

      expect(replayed.pinned?("blake3:aaaa1111")).to be(false)
    end
  end

  # Fix 3: the WRITE guard enforces `in: [true, false]`, so a read side that
  # folds by truthiness trusts more than the writer ever promised. Salvaged and
  # hand-edited journals are exactly what this record type exists to survive.
  describe "a malformed pinned field" do
    def replay_raw(*records) = described_class.new(records.map(&:to_json)).session

    it "refuses a string 'false' rather than replaying it as PINNED" do
      expect { replay_raw({ "type" => "session_pin", "digest" => "blake3:aaaa1111", "pinned" => "false" }) }
        .to raise_error(Lain::Error, /must carry pinned true or false/)
    end

    it "refuses a null pinned rather than silently replaying it as an unpin" do
      expect { replay_raw({ "type" => "session_pin", "digest" => "blake3:aaaa1111", "pinned" => nil }) }
        .to raise_error(Lain::Error, /must carry pinned true or false/)
    end

    it "still raises KeyError when the pinned key is absent entirely" do
      expect { replay_raw({ "type" => "session_pin", "digest" => "blake3:aaaa1111" }) }
        .to raise_error(KeyError)
    end
  end
end
