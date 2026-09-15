# frozen_string_literal: true

RSpec.describe Lain::Context::PinnedMessages do
  def text(body) = [{ "type" => "text", "text" => body }]

  def message(role, body) = { "role" => role, "content" => text(body) }

  def tool_use(id)
    { "role" => "assistant", "content" => [{ "type" => "tool_use", "id" => id, "name" => "grep", "input" => {} }] }
  end

  def tool_result(id)
    { "role" => "user", "content" => [{ "type" => "tool_result", "tool_use_id" => id, "content" => "ok" }] }
  end

  let(:messages) do
    [
      message("user", "a" * 20),
      message("assistant", "b" * 20),
      message("user", "c" * 20),
      message("assistant", "d" * 20)
    ]
  end

  # Scenario: a pin that would strand its counterpart is dropped, not
  # protected alone -- follow-up 14's repair. These examples give no
  # `candidates:`, so the pool IS the literal set built here -- the shape
  # every other `PinnedMessages.new` site in this codebase still uses. The
  # wider closure a real render offers is "pairing against the rendered
  # chain, not only the pinned set", below.
  describe "a tool_use/tool_result pair" do
    it "protects neither half when only the tool_use is in the set" do
      pins = described_class.new([tool_use("t1")])

      expect(pins).to be_none
      expect(pins.protects?(Lain::Canonical.dump(tool_use("t1")))).to be(false)
    end

    it "protects neither half when only the tool_result is in the set" do
      pins = described_class.new([tool_result("t1")])

      expect(pins).to be_none
    end

    it "protects both halves when both are in the set" do
      pins = described_class.new([tool_use("t1"), tool_result("t1")])

      expect(pins.protects?(Lain::Canonical.dump(tool_use("t1")))).to be(true)
      expect(pins.protects?(Lain::Canonical.dump(tool_result("t1")))).to be(true)
    end

    it "leaves an ordinary pinned message alone -- pairing only ever narrows a tool pin" do
      pins = described_class.new([messages[0]])

      expect(pins.protects?(Lain::Canonical.dump(messages[0]))).to be(true)
    end

    it "drops one unanswered tool_use among several answered ones, keeping only the paired pair" do
      pins = described_class.new([tool_use("t1"), tool_result("t1"), tool_use("t2")])

      expect(pins.protects?(Lain::Canonical.dump(tool_use("t1")))).to be(true)
      expect(pins.protects?(Lain::Canonical.dump(tool_result("t1")))).to be(true)
      expect(pins.protects?(Lain::Canonical.dump(tool_use("t2")))).to be(false)
    end
  end

  # Scenario: pairing is read off the TIMELINE BEING RENDERED
  #
  # A turn pinned while its `tool_use` was still PARKED records only that one
  # digest -- {Lain::CLI::Command::Pin::Counterpart#of} has nothing to drag
  # yet. Without this, the turn stayed permanently unprotected even once
  # answered: {Compaction::Source#pinned} rebuilds the pin-fed set fresh every
  # render straight off `session.pinned?(digest)` per turn, and a companion
  # that was never RECORDED is never in that set -- the drop-an-orphan
  # fallback above would then drop the once-parked half forever, silently,
  # despite the CLI reply's promise. `candidates:` is the repair: the turn's
  # counterpart need not be pinned, only present somewhere on the chain this
  # object is asked to protect against.
  #
  # (Converted from `.probes/review/parked_pin_orphan_probe.rb`, which
  # demonstrated the failure directly against `Compaction::Source#pinned`'s
  # own filter-and-construct shape.)
  describe "pairing against the rendered chain, not only the pinned set" do
    it "protects a once-parked tool_use once its answer exists on the chain, though only it was ever pinned" do
      rendered = [tool_use("t1"), tool_result("t1"), message("assistant", "done")]
      pins = described_class.new([tool_use("t1")], candidates: rendered)

      expect(pins).not_to be_none
      expect(pins.protects?(Lain::Canonical.dump(tool_use("t1")))).to be(true)
      expect(pins.protects?(Lain::Canonical.dump(tool_result("t1")))).to be(true)
    end

    # A pin recorded before this repair landed named only ONE digest of a
    # pair -- resuming that session must not read the survivor as
    # unprotected now that its counterpart is visible on the very chain being
    # rendered, even though {Lain::CLI::Command::Pin} never recorded it.
    it "protects a pre-existing lone-half pin whose counterpart is on the rendered chain" do
      rendered = [tool_use("t1"), tool_result("t1")]
      pins = described_class.new([tool_result("t1")], candidates: rendered)

      expect(pins.protects?(Lain::Canonical.dump(tool_use("t1")))).to be(true)
      expect(pins.protects?(Lain::Canonical.dump(tool_result("t1")))).to be(true)
    end

    # A genuinely parked tool_use -- no answer anywhere in `candidates`
    # either -- still drops: there is nothing on the chain to close over, and
    # a parked turn is the head, never inside a droppable span anyway.
    it "still drops a pinned tool_use whose answer is absent from the rendered chain too" do
      pins = described_class.new([tool_use("t1")], candidates: [tool_use("t1")])

      expect(pins).to be_none
    end
  end

  # Scenario: it satisfies ProtectedPatterns' duck -- a String in, a Boolean out
  describe "#protects?" do
    it "protects the canonical dump of a message it was built from" do
      pins = described_class.new([messages[1]])

      expect(pins.protects?(Lain::Canonical.dump(messages[1]))).to be(true)
    end

    it "does not protect a message it was not built from" do
      pins = described_class.new([messages[1]])

      expect(pins.protects?(Lain::Canonical.dump(messages[2]))).to be(false)
    end

    # A pin names ONE message exactly. ProtectedPatterns would treat the dump as
    # a literal SUBSTRING (Regexp.escape) and protect every message containing
    # it -- and a pinned tool_result re-sent inside a longer turn is ordinary.
    it "does not protect a message that merely CONTAINS the pinned bytes" do
      pins = described_class.new([messages[0]])
      containing = "prefix #{Lain::Canonical.dump(messages[0])} suffix"

      expect(pins.protects?(containing)).to be(false)
    end

    it "protects nothing when it was built from nothing" do
      expect(described_class.new.protects?(Lain::Canonical.dump(messages[0]))).to be(false)
      expect(described_class::NONE.protects?(Lain::Canonical.dump(messages[0]))).to be(false)
    end
  end

  describe "#none?" do
    it "is true for an empty pin set" do
      expect(described_class.new).to be_none
      expect(described_class::NONE).to be_none
    end

    it "is false once anything is pinned" do
      expect(described_class.new([messages[0]])).not_to be_none
    end
  end

  # Scenario: a digest is not a dump.
  #
  # Pins are recorded as turn DIGESTS, and a turn's content address folds meta
  # and causal_parents that the projected message never carries. A set built
  # from digests would be well-formed and miss every lookup, silently and
  # forever -- so the constructor refuses anything that is not a message and
  # derives the bytes itself.
  describe "the bytes it is built from" do
    it "refuses a digest String, which would miss every lookup in silence" do
      expect { described_class.new(["blake3:#{"0" * 64}"]) }
        .to raise_error(ArgumentError, /message/)
    end

    it "refuses a Hash that is not a projected message" do
      expect { described_class.new([{ "digest" => "blake3:abc" }]) }
        .to raise_error(ArgumentError, /message/)
    end
  end

  # Scenario: the positional answer {Compaction::Head} filters on, so the head
  # never dumps a message to find out what is pinned.
  describe "#indices_in" do
    it "names the positions of the pinned messages" do
      pins = described_class.new([messages[1], messages[3]])

      expect(pins.indices_in(messages).to_a).to eq([1, 3])
    end

    it "is empty when nothing is pinned, without looking at the messages" do
      expect(described_class::NONE.indices_in(messages).to_a).to eq([])
    end

    it "names a position whose message is absent from the list as nothing at all" do
      pins = described_class.new([message("user", "not in this history")])

      expect(pins.indices_in(messages).to_a).to eq([])
    end

    # THE TWO EQUIVALENCE RELATIONS MUST NOT DRIFT. `#protects?` compares
    # canonical DUMPS, which collapse Symbol keys onto String keys
    # (canonical.rb:18-21); `#indices_in` compares Hashes by `eql?`, which does
    # not. A pin written with Symbol keys inside its content therefore dumped
    # one way and hashed another: Compact protected the message and the head
    # named it anyway -- the over-report, back. The pins are canonicalized ONCE,
    # at construction, so both answers read the same shape.
    it "names a candidate whose pin was written with Symbol keys inside its content" do
      pin = { "role" => "user", "content" => [{ type: "text", text: "pinned" }] }
      pins = described_class.new([pin])
      candidates = [Lain::Canonical.normalize(pin), messages[1]]

      expect(pins.protects?(Lain::Canonical.dump(candidates.first))).to be(true)
      expect(pins.indices_in(candidates).to_a).to eq([0])
    end

    # THE PRECONDITION, stated rather than defended: candidates are
    # canonical-normalized projections. Nothing reaches this through
    # {Compaction::Source} -- an Event's body is normalized at commit, so every
    # Timeline projection is String-keyed -- but `Head.new(messages:)` is public
    # and callers use it, so the contract is written down and pinned here.
    # Checking it per candidate would cost the per-message dump the head exists
    # to avoid.
    it "is out of contract for a candidate that was never canonical-normalized" do
      pins = described_class.new([messages[0]])
      denormalized = { "role" => "user", "content" => [{ type: "text", text: "a" * 20 }] }

      expect(Lain::Canonical.dump(denormalized)).to eq(Lain::Canonical.dump(messages[0]))
      expect(pins.indices_in([denormalized]).to_a).to eq([])
      expect(pins.indices_in([Lain::Canonical.normalize(denormalized)]).to_a).to eq([0])
    end

    # The closure that makes Head and Compact agree. Compact can only ever see
    # TEXT, so pinning one of two byte-identical messages protects both -- and
    # the positional answer has to say so, or the head names a message Compact
    # will keep.
    it "names every byte-identical position, not just the one that was pinned" do
      repeated = message("user", "identical tool result")
      history = [repeated, messages[1], repeated, messages[3]]
      pins = described_class.new([repeated])

      expect(pins.indices_in(history).to_a).to eq([0, 2])
    end
  end

  describe "value-object discipline" do
    it "is Ractor.shareable?, so a Compact holding one can ride the pipeline" do
      expect(described_class.new([messages[0]])).to be_deeply_frozen
    end

    it "snapshots, so a later mutation of the caller's message cannot move it" do
      caller_owned = message("user", "p" * 6)
      pins = described_class.new([caller_owned])
      dump = Lain::Canonical.dump(caller_owned)
      caller_owned["content"].first["text"] << "GROWN"

      expect(pins.protects?(dump)).to be(true)
      expect(pins.protects?(Lain::Canonical.dump(caller_owned))).to be(false)
    end
  end

  # Scenario: the four consumers' signatures do not change -- it IS the
  # protected_patterns: duck.
  describe "as a Context::Compact protection policy" do
    it "keeps a pinned message verbatim ahead of the summary" do
      pins = described_class.new([messages[0]])
      compact = Lain::Context::Compact.new(threshold: 1, keep_last: 1, summarizer: ->(_) { "s" },
                                           protected_patterns: pins)

      result = compact.call(messages)

      expect(result.first).to eq(messages[0])
      expect(result.last).to eq(messages[3])
    end
  end
end
