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
  # FIX 3 (panel round 1): the plan's English -- "the split index equals the
  # one today's slice would use" -- is only true when the naive split ALREADY
  # begins an assistant message. `probe_t2_collapse.rb`'s AC1 sweep found this
  # holds for 5 of 9 `keep_last` values on `alternating(10)` and fails for the
  # other 4 (the even ones, where the naive split lands on `user`). The two
  # branches are both the real rule, not a coincidence one fixture happened to
  # dodge -- so both are pinned here, over the full sweep, rather than one
  # cherry-picked `keep_last`.
  describe "the naive slice, both when it holds and when it is snapped" do
    it "equals today's slice when the naive split already begins an assistant message" do
      messages = alternating(10)

      # keep_last: 3 -> raw = 7, and messages[7] is "assistant" (odd index).
      boundary = described_class.new(messages:, keep_last: 3)

      expect(messages[7]["role"]).to eq("assistant")
      expect(boundary.index).to eq(7)
      expect(boundary.index).to eq(messages.size - 3)
      expect(boundary.moved).to eq(0)
    end

    it "snaps to the nearest earlier assistant-starting index otherwise" do
      messages = alternating(10)

      # keep_last: 4 -> raw = 6, and messages[6] is "user" (even index).
      boundary = described_class.new(messages:, keep_last: 4)

      expect(messages[6]["role"]).to eq("user")
      expect(boundary.index).to eq(5)
      expect(boundary.index).not_to eq(messages.size - 4)
      expect(boundary.moved).to eq(1)
    end

    it "demonstrates both branches across every keep_last on one fixture, not a single hand-picked case" do
      messages = alternating(10)
      # index -> role is deterministic here: even is "user", odd is "assistant".
      # So the naive split (10 - keep_last) already lands on assistant iff it
      # is odd; otherwise the nearest earlier assistant is exactly one back.
      (1..9).each do |keep_last|
        raw = messages.size - keep_last
        expected = raw.odd? ? raw : raw - 1

        boundary = described_class.new(messages:, keep_last:)

        expect(boundary.index).to eq(expected), "keep_last=#{keep_last} raw=#{raw}"
      end
    end
  end

  # Scenario: a cut that would split a tool pair moves off it
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
  end

  # Scenario: the retained tail begins with the role that can follow a user replacement
  describe "a tail that would begin with a user message" do
    it "moves the split so the tail begins with an assistant message" do
      messages = alternating(5) # user, assistant, user, assistant, user

      # keep_last: 3 -> raw split at index 2, which is "user".
      boundary = described_class.new(messages:, keep_last: 3)

      expect(messages[2]["role"]).to eq("user")
      expect(boundary.index).to eq(1)
      expect(messages[boundary.index]["role"]).to eq("assistant")
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

  # FIX 1 (panel round 1, BLOCKER). `land_on_assistant` could walk all the
  # way to index 0 on a history far LONGER than keep_last, and the old
  # `#empty?` could not tell that apart from "nothing was ever droppable" --
  # so `Head#empty?` would read true, `Need` would never fire, and
  # compaction would silently stop happening forever, on a history where
  # nothing else is wrong. T1 ruled that runs of consecutive `user` messages
  # ARE legal production shape (a tool_result turn followed by the human's
  # next ask), so a long run is real, not a fixture artifact --
  # `probe_t2_bruteforce.rb` found 3552 such cases up to history length 9
  # alone. This is what makes `#empty?` and `#declined?` two named states
  # rather than one boolean doing double duty.
  describe "a history with no assistant-starting message within reach of the naive split" do
    it "declines rather than answering an empty span that lies about why" do
      messages = Array.new(40) { |i| message("user", "u#{i}") }

      boundary = described_class.new(messages:, keep_last: 5)

      expect(boundary).to be_declined
      expect(boundary).not_to be_empty # FIX 2: these must not be conflated
      expect(boundary.index).to eq(0)
      expect(boundary.moved).to eq(35) # the full naive split (40 - 5), walked and exhausted
    end

    it "declines on the smallest history that can reproduce it: one droppable user message, no assistant" do
      messages = [message("user", "a"), message("user", "b")]

      boundary = described_class.new(messages:, keep_last: 1)

      expect(boundary).to be_declined
      expect(boundary).not_to be_empty
      expect(boundary.index).to eq(0)
    end

    it "still lands normally when an assistant exists further back than the naive split, however far" do
      # One assistant at index 1, then thirty more user messages -- there IS
      # a valid landing, just a costly one. Not a decline: a real answer that
      # retains far more than requested, which is the honest outcome, not a
      # bug in itself (see FIX 6, `#moved` reports exactly how costly).
      messages = [message("user", "u"), message("assistant", "a")] + Array.new(30) { |i| message("user", "u#{i}") }

      boundary = described_class.new(messages:, keep_last: 3)

      expect(boundary).not_to be_declined
      expect(boundary.index).to eq(1)
      expect(boundary.moved).to eq(28)
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

  # FIX 5. `Context::PinnedMessages` documents the same Symbol-vs-String
  # projection hazard at `pinned_messages.rb:70-80` and `:96-108` because a
  # silent mismatch there is exactly this failure mode: an equality check
  # that quietly never matches. A Boundary that read `messages[index]["role"]`
  # on a Symbol-keyed or role-less projection would silently treat every
  # message as non-assistant and (per FIX 1) correctly decline rather than
  # lie -- but declining because of a MALFORMED precondition is a different,
  # worse-to-hide problem than declining because a legitimate history lacks
  # an assistant. `Hash#fetch` turns the malformed case into a loud, precise
  # failure instead.
  describe "a malformed message projection" do
    it "raises loudly on a message with no \"role\" key at all" do
      messages = Array.new(4) { { "content" => [] } }

      expect { described_class.new(messages:, keep_last: 1) }
        .to raise_error(KeyError, /role/)
    end

    it "raises loudly on Symbol-keyed messages rather than silently declining" do
      messages = (0...10).map { |i| { role: i.even? ? "user" : "assistant", content: [] } }

      expect { described_class.new(messages:, keep_last: 3) }
        .to raise_error(KeyError, /role/)
    end
  end

  # FIX 6. `Head` and `Compact` are handed the SAME `Boundary` instance (T4)
  # and must agree; when they do not, the diagnostic is two integers with no
  # story. `#moved` is that story: 0 when the naive split already landed,
  # the true distance otherwise -- for both a normal landing and a decline.
  describe "#moved, the diagnostic surface" do
    it "is zero when the naive split needs no adjustment" do
      boundary = described_class.new(messages: alternating(10), keep_last: 3)

      expect(boundary.moved).to eq(0)
    end

    it "is the exact distance walked when the split snaps to an earlier assistant" do
      boundary = described_class.new(messages: alternating(10), keep_last: 4)

      expect(boundary.moved).to eq(1)
    end

    it "is the full naive split's distance when declined" do
      messages = Array.new(12) { |i| message("user", "u#{i}") }

      boundary = described_class.new(messages:, keep_last: 2)

      expect(boundary.moved).to eq(10)
      expect(boundary.index).to eq(0)
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

    it "never starts the tail on a non-assistant, never splits a tool pair, and never lets empty? lie" do
      violations = []

      (1..7).each do |len|
        histories(len).each do |kinds|
          messages = build(kinds)
          (1..len).each do |keep_last|
            boundary = described_class.new(messages:, keep_last:)
            index = boundary.index
            raw = [messages.size - keep_last, 0].max

            violations << ["tail_not_assistant", kinds.join, keep_last, index] \
              unless index.zero? || messages[index]["role"] == "assistant"
            violations << ["pair_split", kinds.join, keep_last, index] \
              if index.positive? && kinds[index] == "R"
            violations << ["empty_lies", kinds.join, keep_last, index] \
              if boundary.empty? && messages.size > keep_last

            # FIX ROUND 2. These two assertions define #declined? and #moved,
            # rather than merely observing them -- unlike the three checks
            # above, which would all pass even if #declined? fired whenever
            # #index happened to be 0 for ANY reason (including the mutual-
            # exclusivity example, since that only checks empty? && declined?
            # is never both true, not WHY declined? is true).
            #
            # The landing search only ever considers indices 1..raw, never 0
            # -- {Boundary}'s own contract assumes, and does not verify, that
            # `messages[0]` is `user` in a well-formed conversation (see the
            # class doc), which is what index 0 being "never a valid landing"
            # rests on. This alphabet's `wellformed?` enforces only
            # Correctness gate 2 (tool_use/tool_result pairing), not T1's
            # separate "starts with user" invariant, so a handful of
            # histories here (e.g. "AU") start with "assistant" or a
            # `tool_use` -- outside that assumed precondition. Checking 1..raw
            # rather than 0..raw is deliberate, not a blind spot introduced by
            # this check: it matches what the object itself assumes at index
            # 0, so this assertion characterizes the CURRENT contract exactly
            # rather than a broader one nobody asked this object to satisfy.
            violations << ["declined_but_landing_existed", kinds.join, keep_last, raw] \
              if boundary.declined? && (1..raw).any? { |i| messages[i]["role"] == "assistant" }
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
    it "never splits a tool pair and never starts the tail on a non-assistant message" do
      agentish = [message("user", "ask1"), tool_use_message("t0"), tool_result_message("t0"),
                  message("user", "ask2"), tool_use_message("t1"), tool_result_message("t1"),
                  message("user", "ask3"), message("assistant", "fin")]

      (1..agentish.size).each do |keep_last|
        boundary = described_class.new(messages: agentish, keep_last:)
        index = boundary.index

        expect(index.zero? || agentish[index]["role"] == "assistant").to be(true), "keep_last=#{keep_last}"
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

      expect(Ractor.shareable?(boundary)).to be(true)
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

      expect(Ractor.shareable?(boundary)).to be(true)
    end
  end
end
