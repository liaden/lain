# frozen_string_literal: true

RSpec.describe Lain::Compaction::Boundary do
  def text(body) = [{ "type" => "text", "text" => body }]

  def message(role, body) = { "role" => role, "content" => text(body) }

  def tool_use_message(id)
    { "role" => "assistant", "content" => [{ "type" => "tool_use", "id" => id, "name" => "read", "input" => {} }] }
  end

  def tool_result_message(id)
    block = { "type" => "tool_result", "tool_use_id" => id, "content" => "ok", "is_error" => false }
    { "role" => "user", "content" => [block] }
  end

  # A plain alternating history: user, assistant, user, assistant, ... with no
  # tool calls at all, so raw = size - keep_last is the only thing in play.
  def alternating(count)
    (0...count).map { |i| message(i.even? ? "user" : "assistant", "m#{i}") }
  end

  # Scenario: an unconstrained span snaps to exactly the requested keep_last
  #
  # RE-RULED 2026-07-27 (orchestrator, during T4). This block used to pin TWO
  # branches -- the naive split when it already began an `assistant` message,
  # and a walk back to the nearest earlier one otherwise -- because the
  # replacement was an ASSISTANT message and `summary(assistant) + assistant`
  # is F1's second 400. T4 fixed the replacement's role at `user`, and T1
  # separately ruled that adjacent `user` messages are legal production shape
  # (`agent_spec.rb:407-410`) while only adjacent `assistant` is a violation.
  # A `user` replacement can therefore be followed by EITHER role, so the
  # role rule is not merely weaker than it was -- it is vacuous, and its only
  # remaining effect was to over-restrict. The naive split now stands unless
  # the tool-pair rule moves it. See the class doc.
  describe "the naive slice, which now stands unless a tool pair is in the way" do
    it "equals today's slice when the naive split begins an assistant message" do
      messages = alternating(10)

      # keep_last: 3 -> raw = 7, and messages[7] is "assistant" (odd index).
      boundary = described_class.new(messages:, keep_last: 3)

      expect(messages[7]["role"]).to eq("assistant")
      expect(boundary.index).to eq(7)
      expect(boundary.index).to eq(messages.size - 3)
      expect(boundary.moved).to eq(0)
    end

    # The case the old rule moved and this one does not. It is safe for exactly
    # one reason: the replacement is a `user` message, so `user + user` is the
    # legal adjacency T1 pinned rather than the illegal one F1 measured.
    it "equals today's slice when the naive split begins a USER message too" do
      messages = alternating(10)

      # keep_last: 4 -> raw = 6, and messages[6] is "user" (even index).
      boundary = described_class.new(messages:, keep_last: 4)

      expect(messages[6]["role"]).to eq("user")
      expect(boundary.index).to eq(6)
      expect(boundary.index).to eq(messages.size - 4)
      expect(boundary.moved).to be_zero
    end

    it "equals the naive split at every keep_last on a history with no tool calls at all" do
      messages = alternating(10)

      (1..9).each do |keep_last|
        boundary = described_class.new(messages:, keep_last:)

        expect(boundary.index).to eq(messages.size - keep_last), "keep_last=#{keep_last}"
        expect(boundary.moved).to be_zero, "keep_last=#{keep_last}"
      end
    end
  end

  # Scenario: a cut that would split a tool pair moves off it.
  #
  # T2's NIT 7 coming due. Pair safety used to be EMERGENT: "land on assistant"
  # happened to imply it, because a `tool_result` is always a `user` message
  # immediately after its `assistant` `tool_use`. Relaxing the role rule (T4,
  # orchestrator ruling) removes the thing that was accidentally providing it,
  # so the rule is now written directly -- and tested directly, which is what
  # T2's own warning said would be needed the day the role rule was relaxed.
  describe "a cut that would split a tool pair" do
    it "moves so the pair stays whole on one side" do
      messages = [
        message("user", "ask1"),
        message("assistant", "reply1"),
        message("user", "ask2"),
        tool_use_message("toolu_1"),
        tool_result_message("toolu_1"),
        message("assistant", "final")
      ]

      # keep_last: 2 -> raw split at index 4, which is tool_result_message
      # ("toolu_1")'s position -- squarely between it and its tool_use at
      # index 3.
      boundary = described_class.new(messages:, keep_last: 2)

      expect(boundary.index).to eq(3)
      expect(boundary.index).to eq(4 - 1) # moved by exactly one position
      # both halves of the pair now sit on the tail (kept) side, together
      expect(messages[boundary.index]["content"].first["type"]).to eq("tool_use")
      expect(messages[boundary.index + 1]["content"].first["type"]).to eq("tool_result")
    end

    # The pair is exactly two adjacent messages (Correctness gate 2,
    # `agent.rb:326-328`), so ONE position always clears it. This is also the
    # card's "if landing needs more than two positions, stop" trigger, which the
    # old role rule was quietly violating -- `probe_t2_collapse.rb` measured
    # walks of 8, and the near-decline case walked 28.
    it "never moves by more than one position, over every keep_last of a tool-heavy history" do
      messages = [message("user", "ask")] +
                 (1..6).flat_map { |round| [tool_use_message("t#{round}"), tool_result_message("t#{round}")] }

      (1..messages.size).each do |keep_last|
        boundary = described_class.new(messages:, keep_last:)

        expect(boundary.moved).to be <= 1, "keep_last=#{keep_last} moved=#{boundary.moved}"
      end
    end

    # The guard matches IDS, not block types. A `tool_result` at the head of the
    # tail whose `tool_use` is nowhere near it was already an orphan in the
    # source; moving the cut for it would retain a message for no reason and
    # would report a `moved` the caller cannot act on.
    #
    # DISCRIMINATING FIXTURE, and it has to be: the predecessor carries a
    # `tool_use` of a DIFFERENT id, so a type-only reading ("previous has a
    # tool_use, next has a tool_result") answers 1 while the id reading answers
    # 2. An earlier version of this example used a predecessor with no
    # `tool_use` at all, where the two readings coincide -- so replacing the id
    # intersection with a bare type check left the whole suite green, and the
    # claim "matched by id" was untested. Verified by mutation.
    it "does not move for a tool_result whose tool_use is not the message before it" do
      messages = [message("user", "ask"), tool_use_message("toolu_other"),
                  tool_result_message("toolu_nowhere"), message("assistant", "fin")]

      boundary = described_class.new(messages:, keep_last: 2)

      expect(boundary.index).to eq(2)
      expect(boundary.moved).to be_zero
    end

    # The re-check at the move's DESTINATION, which is the only thing that can
    # produce a decline on a history longer than one droppable message -- and
    # was equally untested until this example: removing the second check left
    # the suite green.
    #
    # It needs a message carrying BOTH a `tool_result` answering the turn before
    # it and a `tool_use` answered by the turn after. That is legal on the wire
    # and nothing in `lib/` emits it (`Agent#perform_tools` commits one user
    # message per assistant turn's results), which is exactly why it must be
    # pinned rather than assumed away. This is T2's NIT 7 one level down: a
    # branch whose safety was emergent from the fixtures rather than asserted.
    it "declines when the move off one pair lands on another" do
      both = { "role" => "assistant",
               "content" => [{ "type" => "tool_result", "tool_use_id" => "a", "content" => "ok" },
                             { "type" => "tool_use", "id" => "b", "name" => "read", "input" => {} }] }
      messages = [message("user", "ask"), tool_use_message("a"), both,
                  tool_result_message("b"), message("assistant", "fin")]

      boundary = described_class.new(messages:, keep_last: 2)

      expect(boundary).to be_declined
      expect(boundary).not_to be_empty
      expect(boundary.index).to be_zero
      # `moved` is the full naive distance when declined, so it is NOT bounded
      # by one here -- the bound is on a cut that lands, not on a refusal.
      expect(boundary.moved).to eq(3)
    end

    # The only shape that still declines: the single droppable message IS the
    # tool_use answered by the first retained one, so the one legal move lands
    # on 0 and there is nothing to drop.
    it "declines when the only droppable message is the tool_use of a retained tool_result" do
      messages = [tool_use_message("t0"), tool_result_message("t0"), message("assistant", "fin")]

      boundary = described_class.new(messages:, keep_last: 2)

      expect(boundary).to be_declined
      expect(boundary).not_to be_empty
      expect(boundary.index).to be_zero
      expect(boundary.moved).to eq(1)
    end
  end

  # Scenario: a span shorter than keep_last is empty rather than negative
  describe "a span no longer than keep_last" do
    it "reports an empty span and retains the whole history" do
      messages = alternating(3)

      boundary = described_class.new(messages:, keep_last: 5)

      expect(boundary.index).to eq(0)
      expect(boundary).to be_empty
      expect(boundary).not_to be_declined
      expect(messages[boundary.index..]).to eq(messages)
    end

    it "is empty exactly at the boundary, history.size == keep_last" do
      messages = alternating(4)

      boundary = described_class.new(messages:, keep_last: 4)

      expect(boundary).to be_empty
      expect(boundary).not_to be_declined
    end
  end

  # FIX 1 (panel round 1, BLOCKER) -- and the shape that FIX addressed is gone.
  # `land_on_assistant` could walk all the way to index 0 on a history far
  # LONGER than keep_last, so `#declined?` was named to keep that apart from
  # "nothing was ever droppable". T1 ruled runs of consecutive `user` messages
  # legal production shape, so those runs are real -- and under the relaxed rule
  # (T4) they no longer move the cut at all, which is what dissolved 44 sibling
  # failures across six spec files that had been asserting compaction over
  # all-user fixtures. `#declined?` STAYS: it is still correct, still
  # mutually exclusive with `#empty?`, and still the only honest answer for the
  # tool-pair shape above. It is now nearly unreachable rather than wrong.
  describe "a long run of user messages, which used to exhaust the search" do
    it "cuts at the naive split rather than declining" do
      messages = Array.new(40) { |i| message("user", "u#{i}") }

      boundary = described_class.new(messages:, keep_last: 5)

      expect(boundary).not_to be_declined
      expect(boundary).not_to be_empty
      expect(boundary.index).to eq(35)
      expect(boundary.moved).to be_zero
    end

    it "cuts on the smallest history that used to reproduce the decline" do
      messages = [message("user", "a"), message("user", "b")]

      boundary = described_class.new(messages:, keep_last: 1)

      expect(boundary).not_to be_declined
      expect(boundary.index).to eq(1)
    end

    # The near-decline the T2 panel found and handed to T4 as a carry-forward:
    # one assistant at index 1, thirty user messages after it, `keep_last: 3`
    # answered index 1 and `moved` 28 -- correct, honest, and a head of ONE
    # message where three were asked, with every predicate reporting normally.
    # The relaxed rule dissolves it: the cut is where it was asked for.
    it "no longer retains 31 of 32 messages when three were asked for" do
      messages = [message("user", "u"), message("assistant", "a")] + Array.new(30) { |i| message("user", "u#{i}") }

      boundary = described_class.new(messages:, keep_last: 3)

      expect(boundary).not_to be_declined
      expect(boundary.index).to eq(29)
      expect(boundary.moved).to be_zero
    end
  end

  # FIX 2: empty? and declined? must be mutually exclusive across every
  # length/keep_last this class accepts, never both true and never
  # ambiguous about which is which.
  describe "empty? and declined? are distinct, never both true" do
    it "is mutually exclusive across a bounded exhaustive sweep of alternating and all-user histories" do
      (0..8).each do |len|
        [alternating(len), Array.new(len) { |i| message("user", "u#{i}") }].each do |messages|
          roles = messages.map { |m| m["role"] }
          (1..(len + 1)).each do |keep_last|
            boundary = described_class.new(messages:, keep_last:)

            detail = "len=#{len} keep_last=#{keep_last} roles=#{roles}"
            expect(boundary.empty? && boundary.declined?).to be(false), detail
          end
        end
      end
    end
  end

  # Scenario: pins inside the span do not move the cut
  describe "pins inside the droppable span" do
    it "leave the split index unchanged" do
      messages = alternating(10)
      pins = Lain::Context::PinnedMessages.new([messages[2]]) # inside the droppable [0...7) span

      unpinned = described_class.new(messages:, keep_last: 3)
      pinned = described_class.new(messages:, keep_last: 3, pins:)

      expect(pinned.index).to eq(unpinned.index)
    end
  end

  # Scenario: a non-positive keep_last is refused at construction
  describe "a non-positive keep_last" do
    it "refuses zero, naming the value" do
      expect { described_class.new(messages: alternating(4), keep_last: 0) }
        .to raise_error(ArgumentError, /keep_last/)
    end

    it "refuses a negative value, naming the value" do
      expect { described_class.new(messages: alternating(4), keep_last: -1) }
        .to raise_error(ArgumentError, /keep_last/)
    end

    it "reproduces Head's rule byte-identically: 1 accepted, size+1 empty" do
      messages = alternating(10)

      expect(described_class.new(messages:, keep_last: 1).index).to eq(9)
      expect(described_class.new(messages:, keep_last: messages.size + 1)).to be_empty
    end
  end

  # FIX 5, re-pointed at the key this object actually reads. It used to read
  # `"role"`; the relaxed rule reads `"content"` instead, so that is where the
  # precondition now bites. The reasoning is unchanged: `Context::PinnedMessages`
  # documents the same Symbol-vs-String projection hazard
  # (`pinned_messages.rb:70-80`) because a silent mismatch is exactly this
  # failure mode -- a lookup that quietly never matches. A Boundary reading
  # `message[:content]` as nil would silently see no tool blocks anywhere and
  # split pairs happily. `Hash#fetch` makes it loud instead.
  #
  # A message with no `"role"` is no longer this object's business at all: the
  # cut rule stopped depending on roles when the replacement's role became
  # fixed, so there is nothing here to be silently wrong about.
  describe "a malformed message projection" do
    it "raises loudly on a message with no \"content\" key at all" do
      messages = Array.new(4) { { "role" => "user" } }

      expect { described_class.new(messages:, keep_last: 1) }
        .to raise_error(KeyError, /content/)
    end

    it "raises loudly on Symbol-keyed messages rather than silently splitting a pair" do
      messages = (0...10).map { |i| { role: i.even? ? "user" : "assistant", content: [] } }

      expect { described_class.new(messages:, keep_last: 3) }
        .to raise_error(KeyError, /content/)
    end
  end

  # FIX 6. `Head` and `Compact` are handed the SAME `Boundary` instance (T4)
  # and must agree; when they do not, the diagnostic is two integers with no
  # story. `#moved` is that story: 0 when the naive split already landed,
  # the true distance otherwise -- for both a normal landing and a decline.
  describe "#moved, the diagnostic surface" do
    it "is zero when the naive split needs no adjustment" do
      boundary = described_class.new(messages: alternating(10), keep_last: 3)

      expect(boundary.moved).to be_zero
    end

    it "is one when the split moves off a tool pair" do
      messages = [message("user", "ask"), tool_use_message("t0"), tool_result_message("t0"),
                  message("assistant", "fin")]

      boundary = described_class.new(messages:, keep_last: 2)

      expect(boundary.index).to eq(1)
      expect(boundary.moved).to eq(1)
    end

    # Still `raw`, and under the relaxed rule a decline can only happen at
    # raw == 1 -- so this now reads 1 rather than the double-digit distances the
    # old backward walk produced. The invariant `index + moved == raw` is what
    # both spellings share, and the sweep below asserts it.
    it "is the full naive split's distance when declined" do
      messages = [tool_use_message("t0"), tool_result_message("t0")]

      boundary = described_class.new(messages:, keep_last: 1)

      expect(boundary).to be_declined
      expect(boundary.moved).to eq(1)
      expect(boundary.index).to be_zero
    end
  end

  # Probes become specs. `probe_t2_bruteforce.rb` swept every well-formed
  # history (Correctness gate 2: every tool_use immediately followed by its
  # tool_result) up to length 9 and every accepted keep_last, and found: 0
  # tails starting on a non-assistant, 0 split tool pairs, and (after this
  # fix round) 0 cases where #empty? lies about a longer-than-keep_last
  # history. Reproduced here at a bounded length so the suite stays fast --
  # this is the real sweep, not one hand-picked history.
  describe "a bounded exhaustive sweep over every well-formed history (probe_t2_bruteforce.rb, reproduced)" do
    def build(kinds)
      kinds.each_with_index.map do |kind, i|
        case kind
        when "U" then message("user", "u#{i}")
        when "A" then message("assistant", "a#{i}")
        when "T" then tool_use_message("t#{i}")
        when "R" then tool_result_message("t#{i - 1}")
        end
      end
    end

    # Well-formed under Correctness gate 2: every T is followed by R, every R
    # preceded by T.
    def wellformed?(kinds)
      kinds.each_index.all? do |i|
        (kinds[i] != "T" || kinds[i + 1] == "R") && (kinds[i] != "R" || (i.positive? && kinds[i - 1] == "T"))
      end
    end

    def histories(len) = %w[U A T R].repeated_permutation(len).select { |k| wellformed?(k) }

    # What a cut actually produces, taken from the object that DECIDES the
    # replacement rather than restated here. Validity is a property of the
    # rendered array, which is why the sweep builds it and asks
    # {Lain::Context::Conversation} -- the object T1 wrote for exactly this --
    # rather than asking what role the tail happens to begin with. That question
    # was a proxy for validity under an assistant replacement, and it is no
    # longer even correlated with it.
    #
    # Reading the replacement from {Lain::Context::Compact} rather than writing
    # `{"role" => "user"}` here is the load-bearing half. {Lain::Compaction::Boundary}'s
    # cut rule is sound ONLY while the replacement is a `user` message: that is
    # what makes both a `user` and an `assistant` tail legal after it, and it is
    # why this object correctly takes no role parameter. A literal here would go
    # on validating a summary nobody emits, so the day anything assigns
    # `assistant` -- the derivation assigns the role, per the Open decisions
    # ruling, which puts it in T9's hands -- every Boundary-derived cut would
    # become F1's 400 again with not one example failing. Now it fails here.
    def rendered(messages, keep_last)
      Lain::Context::Compact.new(threshold: 0, keep_last:, summarizer: ->(_) { "summary" }).call(messages)
    end

    # The object's own rule, restated in the spec's terms rather than in this
    # alphabet's letters. `raw == 1 && kinds[1] == "R"` characterized these
    # FIXTURES -- one block kind per message is an artifact of `build` -- not the
    # object: a message carrying a `tool_result` for the previous turn AND a
    # `tool_use` for the next is legal on the wire, and there a decline happens
    # at `raw` 2 with `moved` 2. Deriving from the predicate is what keeps this
    # assertion true if the alphabet ever grows that letter.
    def splits_pair?(messages, index)
      tool_ids(messages[index - 1], "tool_use", "id")
        .intersect?(tool_ids(messages[index], "tool_result", "tool_use_id"))
    end

    def tool_ids(message, type, key)
      message["content"].select { |block| block["type"] == type }.filter_map { |block| block[key] }
    end

    def declines?(messages, raw)
      raw.positive? && splits_pair?(messages, raw) && (raw == 1 || splits_pair?(messages, raw - 1))
    end

    # Every well-formed source has zero of these, so any that appear were
    # introduced by the cut. Alternation and opening are deliberately NOT in
    # this list: this alphabet's `wellformed?` enforces only Correctness gate 2,
    # so a history like "AAU" carries its own pre-existing alternation
    # violation, and inheriting one is not the same as causing one.
    def cut_rules = %i[unanswered_tool_use orphaned_tool_result split_tool_pair missing_tool_id]

    it "never splits a tool pair, never renders an invalid conversation, and never lets empty? lie" do
      violations = []

      (1..7).each do |len|
        histories(len).each do |kinds|
          messages = build(kinds)
          (1..len).each do |keep_last|
            boundary = described_class.new(messages:, keep_last:)
            index = boundary.index
            raw = [messages.size - keep_last, 0].max

            violations << ["pair_split", kinds.join, keep_last, index] \
              if index.positive? && kinds[index] == "R"
            violations << ["moved_more_than_one", kinds.join, keep_last, boundary.moved] \
              unless boundary.moved <= 1 || boundary.declined?
            violations << ["empty_lies", kinds.join, keep_last, index] \
              if boundary.empty? && messages.size > keep_last

            if index.positive?
              found = Lain::Context::Conversation.new(rendered(messages, keep_last)).violations.map(&:rule)
              violations << ["rendered_invalid", kinds.join, keep_last, index, found] \
                if found.intersect?(cut_rules)
              violations << ["rendered_opening", kinds.join, keep_last, index] \
                if found.include?(:opening_role)
            end

            # FIX ROUND 2, re-derived for the relaxed rule. These two define
            # #declined? and #moved rather than merely observing them: the
            # checks above would all pass even if #declined? fired whenever
            # #index happened to be 0 for any reason.
            #
            # Under the relaxed rule the candidates are exactly `raw` and
            # `raw - 1`, so a decline is fully characterized rather than merely
            # bounded: it happens iff the naive split splits a pair AND moving
            # off it lands on 0 or on another pair. An equality, not an
            # implication -- it also fails if #declined? ever STOPS firing where
            # it must. See {#declines?} for why it is derived from the pair
            # predicate rather than from this alphabet's letters.
            violations << ["declined_mischaracterized", kinds.join, keep_last, raw, boundary.declined?] \
              unless boundary.declined? == declines?(messages, raw)
            violations << ["index_plus_moved_ne_raw", kinds.join, keep_last, index, boundary.moved, raw] \
              unless index + boundary.moved == raw
          end
        end
      end

      expect(violations).to be_empty
    end
  end

  # The real Agent shape has adjacent user messages
  # (spec/lain/agent_spec.rb:407-410 pins %w[user assistant user user]).
  # `probe_t2_collapse.rb` walked this shape and found walks up to 2 --
  # reproduced here as the regression for that specific production shape,
  # distinct from the general bruteforce sweep above.
  describe "the real Agent shape (adjacent user messages from a tool_result turn)" do
    let(:agentish) do
      [message("user", "ask1"), tool_use_message("t0"), tool_result_message("t0"),
       message("user", "ask2"), tool_use_message("t1"), tool_result_message("t1"),
       message("user", "ask3"), message("assistant", "fin")]
    end

    it "never splits a tool pair, and never moves further than the one position it needs" do
      (1..agentish.size).each do |keep_last|
        boundary = described_class.new(messages: agentish, keep_last:)
        landed_on = boundary.index.zero? ? "none" : agentish[boundary.index]["content"].first["type"]

        expect(landed_on).not_to eq("tool_result"), "keep_last=#{keep_last}"
        expect(boundary.moved).to be <= 1, "keep_last=#{keep_last}"
      end
    end

    # Through the real {Lain::Context::Compact}, so the replacement's role comes
    # from the object that decides it rather than from a literal here -- see the
    # sweep's `rendered` helper for why that link must be tested and not assumed.
    it "renders a valid conversation at every keep_last, which is what the role rule used to stand in for" do
      (1..agentish.size).each do |keep_last|
        composed = Lain::Context::Compact.new(threshold: 0, keep_last:, summarizer: ->(_) { "summary" })
                                         .call(agentish)

        expect(Lain::Context::Conversation.new(composed).violations).to be_empty, "keep_last=#{keep_last}"
      end
    end
  end

  # Scenario: the boundary is a pure, shareable value
  describe "purity and shareability" do
    it "answers the same index twice and leaves the input unmutated" do
      messages = alternating(10)
      snapshot = messages.dup

      first = described_class.new(messages:, keep_last: 3).index
      second = described_class.new(messages:, keep_last: 3).index

      expect(first).to eq(second)
      expect(messages).to eq(snapshot)
    end

    it "is Ractor.shareable?" do
      boundary = described_class.new(messages: alternating(10), keep_last: 3)

      expect(boundary).to be_deeply_frozen
    end

    # FIX 4: a non-frozen, duck-typed pins collaborator must not break
    # shareability -- it proves `pins` is genuinely uninvolved in @index,
    # @declined and @moved, not merely absent from the constructor doc.
    it "is Ractor.shareable? even with a non-frozen, duck-typed pins collaborator" do
      loose_pins = Class.new do
        def initialize = @seen = []
        def none? = true
        def protects?(_text) = false
        def indices_in(_messages) = Set.new
      end.new

      boundary = described_class.new(messages: alternating(10), keep_last: 3, pins: loose_pins)

      expect(boundary).to be_deeply_frozen
    end
  end
end
