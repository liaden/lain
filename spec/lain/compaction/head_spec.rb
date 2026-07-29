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

    # The repeated message straddles the cut -- one occurrence inside the
    # dropped span, one inside the kept tail -- which is what makes the set
    # difference lose it: `Array#-` removes EVERY equal element, so the dropped
    # twin vanishes along with the surviving one. The fixture grew a message
    # during T4 so the straddle still happens at this `keep_last`; the claim it
    # makes did not change.
    it "counts duplicates, where a set difference silently would not" do
      repeated = message("user", "identical tool result")
      dupes = [repeated, message("assistant", "unique"), repeated, message("assistant", "keep"), repeated]
      head = described_class.new(messages: dupes, keep_last: 2)
      seen = nil
      compact = Lain::Context::Compact.new(threshold: 1, keep_last: 2,
                                           summarizer: ->(dropped) { (seen = dropped) && "s" })
      survivors = compact.call(dupes).drop(1)

      expect(head.messages.size).to eq(3)
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

    # THE OPEN QUESTION, ANSWERED (B2, 2026-07-25). This example used to record
    # the opposite -- "names the whole candidate span, protected survivors
    # included" -- as a characterization of the over-report a configured
    # protection policy produced. Wiring pins made that over-report real, so the
    # ruling changed rather than the silence continuing: the SAME policy object
    # goes to both, and the head is now exactly what Compact summarizes, byte
    # for byte.
    it "excludes the protected survivors it once named, leaving exactly what Compact summarizes" do
      pinned = message("user", "SECRET")
      history = [pinned] + messages.drop(1)
      pins = Lain::Context::PinnedMessages.new([pinned])
      head = described_class.new(messages: history, keep_last: 1, pins:)
      summarized = nil
      compact = Lain::Context::Compact.new(
        threshold: 1, keep_last: 1, protected_patterns: pins,
        summarizer: ->(dropped) { (summarized = dropped) && "s" }
      )
      output = compact.call(history)

      expect(head.messages).to eq(history[1..2])
      expect(summarized).to eq(head.messages)
      expect(output.first).to eq(pinned)
      expect(head.bytesize).to eq(Lain::Canonical.dump(summarized).bytesize)
    end

    it "is empty exactly where Compact bails without dropping anything" do
      head = described_class.new(messages:, keep_last: messages.size)
      compact = Lain::Context::Compact.new(threshold: 1, keep_last: messages.size, summarizer:)

      expect(head).to be_empty
      expect(compact.call(messages)).to eq(messages)
    end
  end

  # B2. A pin is recorded as a turn DIGEST while Compact only ever sees
  # projected TEXT, so the mapping between them is made ONCE -- in
  # {Lain::Compaction::Source}, the one object holding both the timeline and the
  # session -- and the SAME {Lain::Context::PinnedMessages} value is then handed
  # to the head and to the Compact. These examples build one by hand because
  # that is what the spec is about; nothing in `lib/` builds one anywhere else.
  describe "pins" do
    def projected(line) = line.to_a.map { |turn| { "role" => turn.role, "content" => turn.content } }

    def pins_for(*pinned) = Lain::Context::PinnedMessages.new(pinned)

    # Scenario: the candidate head excludes pinned messages
    it "excludes a pinned turn, and its bytesize counts only the rest" do
      line = timeline_of(6)
      pinned = projected(line)[2]
      rest = projected(line)[0..3] - [pinned]
      head = described_class.from_timeline(timeline: line, keep_last: 2, pins: pins_for(pinned))

      expect(head.messages).to eq(rest)
      expect(head.bytesize).to eq(Lain::Canonical.dump(rest).bytesize)
    end

    # Scenario: no pins behaves exactly as today
    it "names the whole candidate span when nothing is pinned" do
      line = timeline_of(6)
      unpinned = described_class.from_timeline(timeline: line, keep_last: 2,
                                               pins: Lain::Context::PinnedMessages::NONE)

      expect(unpinned.messages).to eq(projected(line)[0..3])
      expect(unpinned.messages).to eq(described_class.from_timeline(timeline: line, keep_last: 2).messages)
      expect(unpinned.bytesize).to eq(described_class.from_timeline(timeline: line, keep_last: 2).bytesize)
    end

    it "is empty when every droppable turn is pinned, which is what makes Source decline" do
      line = timeline_of(4)
      head = described_class.from_timeline(timeline: line, keep_last: 2, pins: pins_for(*projected(line)[0..1]))

      expect(head).to be_empty
    end

    it "leaves a pinned turn inside the kept tail alone -- the tail is sliced off the FULL list" do
      line = timeline_of(6)
      head = described_class.from_timeline(timeline: line, keep_last: 2, pins: pins_for(projected(line)[5]))

      expect(head.messages).to eq(projected(line)[0..3])
      expect(head.messages).to eq(described_class.from_timeline(timeline: line, keep_last: 2).messages)
    end

    # Scenario: Head and Compact agree on what is droppable.
    #
    # A property, not an example: the asymmetry (a head filtered on turns, a
    # Compact filtered on text) is the whole design and the thing most likely to
    # be quietly broken, so every history size, every keep_last and every subset
    # of the history is exercised -- including histories of REPEATED messages,
    # where pinning one occurrence protects both and the head has to say so.
    describe "agreement with what Compact actually removes" do
      # The third family ALTERNATES, and it is not decoration: with T4's
      # boundary an all-user history has no legal cut at all, so the first two
      # families exercise only the declined path and a sweep built from them
      # alone would agree vacuously, every cell dropping nothing.
      def histories
        (1..4).flat_map do |size|
          [(1..size).map { |index| message("user", "m#{index}") },
           (1..size).map { |index| message("user", "m#{index % 2}") },
           (1..size).map { |index| message(index.odd? ? "user" : "assistant", "m#{index}") }]
        end
      end

      def pin_sets(history)
        (0...(1 << history.size)).map do |mask|
          history.each_index.select { |index| mask.anybits?(1 << index) }.map { |index| history[index] }
        end
      end

      def cases
        histories.flat_map do |history|
          pin_sets(history).product((1..4).to_a).map { |pinned, keep_last| [history, pinned, keep_last] }
        end
      end

      it "hands Compact's summarizer exactly the head's messages, for every pin set" do
        cases.each do |history, pinned, keep_last|
          pins = pins_for(*pinned)
          head = described_class.new(messages: history, keep_last:, pins:)
          seen = :summarizer_never_called
          compact = Lain::Context::Compact.new(threshold: 1, keep_last:, protected_patterns: pins,
                                               summarizer: ->(dropped) { (seen = dropped) && "s" })
          compact.call(history)
          # `head.empty?`, not `history.size <= keep_last`: T4 gave Compact three
          # more ways to drop nothing -- a declined boundary, a boundary that
          # snapped to 0, and a span whose every message is pinned -- and in all
          # of them the summarizer must not be called at all. An empty head is
          # now exactly the cases where it is not.
          expected = head.empty? ? :summarizer_never_called : head.messages

          expect(seen).to eq(expected), "size=#{history.size} keep_last=#{keep_last} pinned=#{pinned.size}"
        end
      end

      # Scenario: Compact's own threshold measures the same set the Head
      # measured. The pinned message is big, so a threshold between the two
      # sizes discriminates: gate on `dropped` and both calls compact.
      it "sets the threshold Compact obeys: at the head's size it compacts, one byte above it defers" do
        pinned = message("user", "PINNED #{"p" * 200}")
        history = [pinned] + messages
        pins = pins_for(pinned)
        head = described_class.new(messages: history, keep_last: 2, pins:)

        expect(compacting(history, pins, head.bytesize)).not_to eq(history)
        expect(compacting(history, pins, head.bytesize + 1)).to eq(history)
        expect(head.bytesize).to be < Lain::Canonical.dump(history[0...-2]).bytesize
      end

      def compacting(history, pins, threshold)
        Lain::Context::Compact.new(threshold:, keep_last: 2, protected_patterns: pins,
                                   summarizer: ->(_) { "s" }).call(history)
      end

      # The other half of the same agreement: what SURVIVES is the protected
      # messages plus the tail, and the head is precisely the complement.
      it "measures exactly the bytes Compact's threshold measures, for every pin set" do
        cases.reject { |history, _, keep_last| history.size <= keep_last }.each do |history, pinned, keep_last|
          pins = pins_for(*pinned)
          head = described_class.new(messages: history, keep_last:, pins:)
          summarizable = nil
          compact = Lain::Context::Compact.new(threshold: 1, keep_last:, protected_patterns: pins,
                                               summarizer: ->(dropped) { (summarizable = dropped) && "s" })
          compact.call(history)

          # `|| []` covers the cells where Compact drops nothing and never calls
          # the summarizer: an empty head measures the 2 bytes of "[]", so the
          # equality still discriminates rather than being satisfied by nil.
          expect(head.bytesize).to eq(Lain::Canonical.dump(summarizable || []).bytesize),
                                   "size=#{history.size} keep_last=#{keep_last} pinned=#{pinned.size}"
        end
      end
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

    # Through the {Lain::Compaction::Boundary} this object builds first, which is
    # where the rule is applied -- so what these two pin is that a Head cannot be
    # constructed around a degenerate keep_last, and that the module's message is
    # what a caller reads. The exact string, not `/keep_last/`: a door quietly
    # relaxing to different wording is the same defect as one relaxing the rule.
    it "refuses zero, which Compact turns into total history loss" do
      expect { described_class.new(messages:, keep_last: 0) }
        .to raise_error(ArgumentError, "keep_last must be positive, got 0")
    end

    # UPDATED BY T4, not deleted. This used to record the divergence itself --
    # Compact replacing the entire history with a summary of zero messages while
    # the head reported nothing droppable. Every consumer now asks
    # {Lain::Compaction.validate_keep_last}, so they refuse the same values with
    # the same message and the total-history-loss path is unreachable rather than
    # merely guarded one level up (`compaction_spec.rb` sweeps the doors).
    # At CONSTRUCTION, everywhere: a wiring error must fail at wiring time,
    # because the alternative is raising inside `Context#render` on the first turn
    # of a live chat -- which `Boundary`'s doc argues is worse than not compacting
    # at all.
    it "documents that Compact now refuses zero by the same rule, instead of losing the whole history" do
      expect { Lain::Context::Compact.new(threshold: 1, keep_last: 0, summarizer:) }
        .to raise_error(ArgumentError, /keep_last must be positive, got 0/)
    end

    it "refuses a negative keep_last, which Compact cannot even run" do
      expect { described_class.new(messages:, keep_last: -1) }
        .to raise_error(ArgumentError, "keep_last must be positive, got -1")
    end

    # Also updated by T4: Compact still raises, but on the RULE rather than on
    # `Array#last`'s "negative array size" -- which named the symptom and not
    # the argument that caused it.
    it "documents that Compact refuses a negative keep_last, now naming the argument" do
      expect { Lain::Context::Compact.new(threshold: 1, keep_last: -1, summarizer:) }
        .to raise_error(ArgumentError, /keep_last must be positive, got -1/)
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
    #
    # Both role shapes, since T4: an all-user history has no legal cut and
    # exercises only the DECLINED path, so a sweep over it alone would agree
    # about nothing at all.
    it "agrees with Compact at every history size and every keep_last it accepts" do
      shapes(0..5).each do |history|
        (1..6).each do |keep_last|
          head = described_class.new(messages: history, keep_last:)
          seen = :summarizer_never_called
          compact = Lain::Context::Compact.new(threshold: 1, keep_last:,
                                               summarizer: ->(dropped) { (seen = dropped) && "s" })
          compact.call(history)
          expected = head.empty? ? :summarizer_never_called : head.messages

          expect(seen).to eq(expected), "roles=#{history.map { |m| m["role"] }} keep_last=#{keep_last}"
        end
      end
    end

    def shapes(sizes)
      sizes.flat_map do |size|
        [(1..size).map { |index| message("user", "m#{index}") },
         (1..size).map { |index| message(index.odd? ? "user" : "assistant", "m#{index}") }]
      end
    end
  end

  # T4. The cut rule is {Lain::Compaction::Boundary}'s, consulted here and by
  # {Lain::Context::Compact} with the same arguments -- and its two diagnostics
  # are answered by this object because this is the one
  # {Lain::Compaction::Source} already holds when it journals the turn's
  # decision, so reading them costs no new collaborator.
  describe "the boundary it consults" do
    def tool_use_message(id)
      { "role" => "assistant",
        "content" => [{ "type" => "tool_use", "id" => id, "name" => "read", "input" => {} }] }
    end

    def tool_result_message(id)
      { "role" => "user", "content" => [{ "type" => "tool_result", "tool_use_id" => id, "content" => "ok" }] }
    end

    it "takes the naive split whenever no tool pair is in the way" do
      (1..3).each do |keep_last|
        head = described_class.new(messages:, keep_last:)

        expect(head.messages).to eq(messages[0...-keep_last]), "keep_last=#{keep_last}"
        expect(head.moved).to be_zero, "keep_last=#{keep_last}"
      end
    end

    it "moves the cut back one when it would strand a tool_result, and says so" do
      history = [message("user", "ask"), tool_use_message("t0"), tool_result_message("t0"),
                 message("assistant", "fin")]
      head = described_class.new(messages: history, keep_last: 2)

      expect(head.messages).to eq(history[0..0])
      expect(head.moved).to eq(1)
      expect(head).not_to be_declined
    end

    # THE CARRY-FORWARD (T2 panel review), and the regression for the ruling
    # that dissolved it. One assistant landing at index 1 and thirty user
    # messages after it used to answer index 1 and `moved` 28 -- a head of ONE
    # message where three were asked, with nothing raising, no predicate
    # reporting trouble, {Need} never crossing threshold, and compaction quietly
    # stopping for the rest of the session. The relaxed boundary cuts where it
    # was asked to, so the shape is now unremarkable; `#moved` says so, and is
    # still the surface T5 journals for the cases that are not.
    it "no longer walks a long run of user messages, so the near-decline cannot recur" do
      history = [message("user", "ask"), message("assistant", "landing")] +
                Array.new(30) { |index| message("user", "ask #{index}") }
      head = described_class.new(messages: history, keep_last: 3)

      expect(head.messages.size).to eq(29)
      expect(head.moved).to be_zero
      expect(head).not_to be_declined
    end

    # A declined boundary and a vacuous request are both empty heads and must
    # not read alike: one was refused a legal cut, the other was never asked for
    # one. `#moved` separates them numerically as well.
    it "declines when the only droppable message is the tool_use of a retained tool_result" do
      history = [tool_use_message("t0"), tool_result_message("t0"), message("assistant", "fin")]
      head = described_class.new(messages: history, keep_last: 2)

      expect(head).to be_empty
      expect(head).to be_declined
      expect(head.moved).to eq(1)
    end

    it "is empty but not declined when the span was never asked for" do
      head = described_class.new(messages:, keep_last: messages.size)

      expect(head).to be_empty
      expect(head).not_to be_declined
      expect(head.moved).to be_zero
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
