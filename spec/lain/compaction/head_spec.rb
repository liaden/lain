# frozen_string_literal: true

RSpec.describe Lain::Compaction::Head do
  def text(body) = [{ "type" => "text", "text" => body }]

  def message(role, body) = { "role" => role, "content" => text(body) }

  def timeline_of(count)
    (1..count).inject(Lain::Timeline.empty(store: Lain::Store.new)) do |timeline, index|
      timeline.commit(role: index.odd? ? :user : :assistant, content: text("turn #{index}"))
    end
  end

  let(:messages) do
    [
      message("user", "a" * 200),
      message("assistant", "b" * 200),
      message("user", "c" * 200),
      message("assistant", "d" * 200)
    ]
  end

  # Scenario: the head excludes the kept tail
  describe "the slice" do
    it "holds the first seven messages of a ten-turn timeline in timeline order" do
      head = described_class.from_timeline(timeline: timeline_of(10), keep_last: 3)

      expect(head.messages.size).to eq(7)
      expect(head.messages.map { |m| m["content"].first["text"] }).to eq((1..7).map { |i| "turn #{i}" })
    end

    it "projects a turn exactly as Context#render does" do
      head = described_class.from_timeline(timeline: timeline_of(2), keep_last: 1)

      expect(head.messages).to eq([{ "role" => "user", "content" => text("turn 1") }])
    end

    it "enumerates its messages" do
      head = described_class.new(messages:, keep_last: 1)

      expect(head.to_a).to eq(messages[0..2])
      expect(head).to be_a(Enumerable)
    end
  end

  # Scenario: the head's byte size is the canonical dump size
  describe "the measurement" do
    it "equals the canonical dump bytesize of its messages" do
      head = described_class.new(messages:, keep_last: 1)

      expect(head.bytesize).to eq(Lain::Canonical.dump(messages[0..2]).bytesize)
    end

    # FIX 2 (panel). The one object whose job is to be the single answer must
    # not answer its own question two ways, so the dump is unconditional --
    # including for an empty head, where it is the 2 bytes of "[]".
    it "answers exactly one way, at every size including empty" do
      [1, 2, 3, 4, 9].each do |keep_last|
        head = described_class.new(messages:, keep_last:)

        expect(head.bytesize).to eq(Lain::Canonical.dump(head.messages).bytesize), "keep_last=#{keep_last}"
      end
    end
  end

  # Scenario: the head agrees with what Compact would drop
  describe "agreement with Context::Compact" do
    let(:summarizer) { ->(dropped) { "summary of #{dropped.size}" } }

    # FIX 4 (panel): `messages - compact.call(messages)` was a SET difference
    # and under-counted whenever a dropped message was byte-equal to a kept one
    # -- which repeated tool results produce routinely. The survivors are
    # compared positionally instead: Compact's output is one summary followed
    # by the verbatim tail, so "what it removed" is exactly the prefix that the
    # tail is missing.
    it "holds exactly the prefix Compact replaces with its summary" do
      head = described_class.new(messages:, keep_last: 2)
      compact = Lain::Context::Compact.new(threshold: 1, keep_last: 2, summarizer:)
      survivors = compact.call(messages).drop(1)

      expect(survivors).to eq(messages.drop(head.messages.size))
      expect(head.messages).to eq(messages.take(messages.size - survivors.size))
    end

    it "counts duplicates, where a set difference silently would not" do
      repeated = message("user", "identical tool result")
      dupes = [repeated, message("assistant", "unique"), repeated, message("user", "tail")]
      head = described_class.new(messages: dupes, keep_last: 2)
      seen = nil
      compact = Lain::Context::Compact.new(threshold: 1, keep_last: 2,
                                           summarizer: ->(dropped) { (seen = dropped) && "s" })
      survivors = compact.call(dupes).drop(1)

      expect(head.messages.size).to eq(2)
      expect(seen).to eq(head.messages)
      expect(survivors).to eq(dupes.last(2))
      expect(dupes - compact.call(dupes)).not_to eq(head.messages)
    end

    it "hands Compact's summarizer exactly the head's messages" do
      head = described_class.new(messages:, keep_last: 2)
      seen = nil
      compact = Lain::Context::Compact.new(threshold: 1, keep_last: 2,
                                           summarizer: ->(dropped) { (seen = dropped) && "s" })
      compact.call(messages)

      expect(seen).to eq(head.messages)
    end

    it "measures the same bytes Compact thresholds: at the head's size Compact compacts" do
      head = described_class.new(messages:, keep_last: 2)
      compact = Lain::Context::Compact.new(threshold: head.bytesize, keep_last: 2, summarizer:)

      expect(compact.call(messages)).not_to eq(messages)
    end

    it "measures the same bytes Compact thresholds: one byte above, Compact defers" do
      head = described_class.new(messages:, keep_last: 2)
      compact = Lain::Context::Compact.new(threshold: head.bytesize + 1, keep_last: 2, summarizer:)

      expect(compact.call(messages)).to eq(messages)
    end

    # OPEN QUESTION, pinned rather than left silent (this card's escalation
    # trigger). Under a CONFIGURED ProtectedPatterns, Compact keeps the
    # protected messages and summarizes only the rest, so the head names a
    # SUPERSET of what is removed and over-reports its bytes. No production
    # site configures protected_patterns today -- every Compact in lib/ and
    # bench/ takes the NONE default -- so nothing over-reports yet. Whether
    # Head should subtract the protected span is a policy call; this example
    # records today's behavior so a future ruling has to change a test.
    it "names the whole candidate span, protected survivors included" do
      protected_first = [message("user", "SECRET")] + messages.drop(1)
      head = described_class.new(messages: protected_first, keep_last: 1)
      summarized = nil
      compact = Lain::Context::Compact.new(
        threshold: 1, keep_last: 1, protected_patterns: Lain::Context::ProtectedPatterns.new(["SECRET"]),
        summarizer: ->(dropped) { (summarized = dropped) && "s" }
      )
      output = compact.call(protected_first)

      expect(head.messages).to eq(protected_first[0..2])
      expect(summarized).to eq(protected_first[1..2])
      expect(output.first).to eq(protected_first.first)
      expect(head.bytesize).to be > Lain::Canonical.dump(summarized).bytesize
    end

    it "is empty exactly where Compact bails without dropping anything" do
      head = described_class.new(messages:, keep_last: messages.size)
      compact = Lain::Context::Compact.new(threshold: 1, keep_last: messages.size, summarizer:)

      expect(head).to be_empty
      expect(compact.call(messages)).to eq(messages)
    end
  end

  # Scenario: a timeline shorter than keep_last yields an empty head.
  #
  # The card's wording is "its size is zero". Ruling 2026-07-25 (panel, FIX 2)
  # overrode that literal reading: `bytesize` is the UNCONDITIONAL canonical
  # dump, so an empty head measures the 2 bytes of "[]". Special-casing it to
  # zero made this object answer its own question two ways, and bought nothing
  # -- `Need::TokenThreshold` re-dumps the messages itself (`need.rb:51`) and
  # never reads `bytesize`, while `Compact` declines at `compact.rb:50`
  # regardless of the number. Emptiness is asked with `#empty?`.
  describe "a history no longer than the kept tail" do
    it "is empty" do
      head = described_class.from_timeline(timeline: timeline_of(2), keep_last: 3)

      expect(head.messages).to be_empty
      expect(head).to be_empty
    end

    it "measures an empty head as the canonical dump of an empty list" do
      head = described_class.new(messages: [], keep_last: 3)

      expect(head.bytesize).to eq(Lain::Canonical.dump([]).bytesize)
      expect(head.bytesize).to eq(2)
    end

    it "does not let an empty head under-report against Compact, which declines either way" do
      head = described_class.new(messages: [], keep_last: 3)
      compact = Lain::Context::Compact.new(threshold: 1, keep_last: 3, summarizer: ->(_) { "s" })

      expect(compact.call([])).to eq([])
      expect(head.bytesize).to eq(Lain::Canonical.dump(head.messages).bytesize)
    end
  end

  # FIX 1 (panel, probe_a5_boundaries.rb). The coupling fixture originally
  # exercised only keep_last >= 1, and both degenerate values diverge --
  # keep_last: 0 in the INVERTED direction, which is the worse one.
  describe "the keep_last boundary" do
    let(:summarizer) { ->(dropped) { "summary of #{dropped.size}" } }

    it "refuses zero, which Compact turns into total history loss" do
      expect { described_class.new(messages:, keep_last: 0) }
        .to raise_error(ArgumentError, /keep_last/)
    end

    it "documents the Compact behavior that zero is refused for" do
      compact = Lain::Context::Compact.new(threshold: 1, keep_last: 0, summarizer:)

      expect(compact.call(messages).size).to eq(1)
      expect(compact.call(messages).first["content"].first["text"]).to eq("summary of 0")
    end

    it "refuses a negative keep_last, which Compact cannot even run" do
      expect { described_class.new(messages:, keep_last: -1) }
        .to raise_error(ArgumentError, /keep_last/)
    end

    it "documents that Compact raises on a negative keep_last" do
      compact = Lain::Context::Compact.new(threshold: 1, keep_last: -1, summarizer:)

      expect { compact.call(messages) }.to raise_error(ArgumentError, /negative array size/)
    end

    it "accepts one, the smallest keep_last Compact handles sanely" do
      expect(described_class.new(messages:, keep_last: 1).messages).to eq(messages[0..2])
    end

    it "accepts a keep_last longer than the history, yielding an empty head" do
      expect(described_class.new(messages:, keep_last: messages.size + 1)).to be_empty
    end

    # `seen` starts at a sentinel, NOT at []: where size <= keep_last Compact
    # returns at `compact.rb:50` without ever calling the summarizer, and an []
    # initializer would match the empty head by coincidence -- 26 of these 36
    # cells asserting nothing (round-2 FIX 2). The sentinel makes those cells
    # assert the real claim, which is that no drop happened at all.
    it "agrees with Compact at every history size and every keep_last it accepts" do
      (0..5).each do |size|
        history = (1..size).map { |index| message("user", "m#{index}") }
        (1..6).each do |keep_last|
          head = described_class.new(messages: history, keep_last:)
          seen = :summarizer_never_called
          compact = Lain::Context::Compact.new(threshold: 1, keep_last:,
                                               summarizer: ->(dropped) { (seen = dropped) && "s" })
          compact.call(history)
          expected = head.empty? ? :summarizer_never_called : head.messages

          expect(seen).to eq(expected), "size=#{size} keep_last=#{keep_last}"
        end
      end
    end
  end

  # FIX 3 (panel, probe_a5_shape_and_dupes.rb §A). A frozen Head over mutable
  # Hashes is a value object that lies: the probe mutated a message the head
  # held and watched bytesize (313) stop matching its own messages (269).
  describe "value-object discipline" do
    it "is deeply frozen, so its measurement cannot go stale" do
      head = described_class.new(messages:, keep_last: 1)

      expect(head).to be_frozen
      expect(head.messages).to be_frozen
      expect(head.messages.first).to be_frozen
      expect(head.messages.first["content"].first["text"]).to be_frozen
    end

    it "refuses the mutation that made the measurement stale" do
      head = described_class.new(messages:, keep_last: 1)

      expect { head.messages.first["content"].first["text"] << "MUTATED" }.to raise_error(FrozenError)
      expect(head.bytesize).to eq(Lain::Canonical.dump(head.messages).bytesize)
    end

    # Round-2 FIX 1 (panel, probe_review2_a5b.rb §B). Freezing in place froze
    # only the SLICE, which left the caller holding a half-frozen array -- and
    # froze nothing at all when size <= keep_last. A Head snapshots; it does not
    # reach back into its argument. This matters as soon as anything builds two
    # Heads from one list at different keep_last.
    it "leaves the caller's array and every element of it untouched" do
      caller_owned = messages
      described_class.new(messages: caller_owned, keep_last: 1)

      expect(caller_owned).not_to be_frozen
      expect(caller_owned.map(&:frozen?)).to all(be(false))
      expect { caller_owned.last["role"] = "still mine" }.not_to raise_error
      expect { caller_owned.first["content"].first["text"] << "!" }.not_to raise_error
    end

    it "snapshots, so a later mutation of the caller's array cannot move it" do
      caller_owned = messages
      head = described_class.new(messages: caller_owned, keep_last: 1)
      before = head.bytesize
      caller_owned.first["content"].first["text"] << "GROWN"

      expect(head.messages.first["content"].first["text"]).not_to include("GROWN")
      expect(head.bytesize).to eq(before)
    end

    it "touches nothing when the history is no longer than the kept tail" do
      caller_owned = messages
      described_class.new(messages: caller_owned, keep_last: caller_owned.size)

      expect(caller_owned.map(&:frozen?)).to all(be(false))
    end

    # CLAUDE.md requires this of value objects, and A6 hands a Head to code
    # that runs through Ractor.make_shareable.
    it "is Ractor.shareable? whichever way it was built" do
      expect(Ractor.shareable?(described_class.new(messages:, keep_last: 1))).to be(true)
      expect(Ractor.shareable?(described_class.from_timeline(timeline: timeline_of(4), keep_last: 1))).to be(true)
    end
  end
end
