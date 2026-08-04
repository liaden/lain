# frozen_string_literal: true

RSpec.describe Lain::Context::Conversation do
  def text(body) = { "type" => "text", "text" => body }

  def tool_use(id) = { "type" => "tool_use", "id" => id, "name" => "read", "input" => { "path" => "a.rb" } }

  def tool_result(id) = { "type" => "tool_result", "tool_use_id" => id, "content" => "ok", "is_error" => false }

  def user(*blocks) = { "role" => "user", "content" => blocks }

  def assistant(*blocks) = { "role" => "assistant", "content" => blocks }

  def violation(messages, rule)
    described_class.new(messages).violations.find { |found| found.rule == rule }
  end

  describe "a well-formed conversation" do
    it "reports no violations and answers that it is valid" do
      messages = [user(text("hi")), assistant(text("hello")), user(text("more"))]

      conversation = described_class.new(messages)

      expect(conversation.violations).to be_empty
      expect(conversation).to be_valid
    end

    it "permits an answered tool round: tool_use then the tool_result immediately after" do
      messages = [
        user(text("read a.rb")),
        assistant(tool_use("toolu_0")),
        user(tool_result("toolu_0")),
        assistant(text("done"))
      ]

      expect(described_class.new(messages).violations).to be_empty
    end

    # The Agent's own shape (spec/lain/agent_spec.rb:407 pins %w[user assistant
    # user user]): perform_tools commits ONE user message of tool_results, and
    # the human's next ask is the user message right after it. Adjacent user
    # messages are therefore ordinary, and only adjacent ASSISTANT messages are
    # refused -- the rule the ruling in the class doc records.
    it "permits adjacent user messages, which is what the Agent commits every tool round" do
      messages = [
        user(text("first")),
        assistant(tool_use("toolu_0")),
        user(tool_result("toolu_0")),
        user(text("second"))
      ]

      expect(described_class.new(messages)).to be_valid
    end
  end

  describe "the opening role" do
    it "refuses an assistant-first array, naming position 0 and the offending role" do
      messages = [assistant(text("summary")), user(text("hi"))]

      found = violation(messages, :opening_role)

      expect(found.positions).to eq([0])
      expect(found.message).to include("assistant")
      expect(described_class.new(messages)).not_to be_valid
    end
  end

  describe "alternation" do
    it "refuses two adjacent assistant messages, naming both positions" do
      messages = [user(text("hi")), assistant(text("one")), assistant(text("two"))]

      found = violation(messages, :alternation)

      expect(found.positions).to eq([1, 2])
      expect(found.message).to include("1", "2")
    end

    # Finding 6: the rule is "neither is a user message". A rendered array can
    # carry a role Compact wrote in without normalize_role, so a violation that
    # asserted "both assistant" would describe a `system` message it never read.
    it "does not call an unknown role assistant" do
      messages = [user(text("hi")), assistant(text("a")), { "role" => "system", "content" => [text("s")] }]

      expect(violation(messages, :alternation).message).not_to include("assistant")
    end
  end

  # Invariant 5, added by T5's panel round. The producer it exists for is a
  # derivation whose strategy echoes the blocks of the span it collapsed: the
  # replacement's role is fixed at `user` (the Messages API requires
  # `messages[0]` to be one), so an echoed `tool_use` lands in a user message.
  # Every other rule here calls that array valid, and the wire returns 400.
  describe "block/role compatibility" do
    it "refuses a tool_use in a user message, naming the block and the role it needs" do
      messages = [user(text("hi")), user(tool_use("toolu_0")), user(tool_result("toolu_0"))]

      found = violation(messages, :misplaced_block)

      expect(found.positions).to eq([1])
      expect(found.subject).to eq("toolu_0")
      expect(found.message).to include("tool_use", "assistant")
    end

    it "refuses a tool_result in an assistant message" do
      messages = [user(text("hi")), assistant(tool_use("toolu_0")), assistant(tool_result("toolu_0"))]

      found = violation(messages, :misplaced_block)

      expect(found.positions).to eq([2])
      expect(found.subject).to eq("toolu_0")
      expect(found.message).to include("tool_result", "user")
    end

    # The shape the panel actually built against the derivation: an echoing
    # strategy over one range. Pairing is satisfied -- the use is answered by
    # the result immediately after it -- so this array passed every other rule.
    it "refuses an echoed tool round whose pairing is otherwise perfect" do
      messages = [user(text("hi")), user(tool_use("toolu_0")), user(tool_result("toolu_0")),
                  assistant(text("done"))]

      conversation = described_class.new(messages)

      expect(conversation.violations.map(&:rule)).to eq([:misplaced_block])
      expect(conversation).not_to be_valid
    end

    it "names each misplaced block separately, so two ids at one position do not fuse" do
      messages = [user(text("hi")), user(tool_use("toolu_0"), tool_use("toolu_1"))]

      found = described_class.new(messages).violations.select { |candidate| candidate.rule == :misplaced_block }

      expect(found.map(&:subject)).to eq(%w[toolu_0 toolu_1])
    end

    # Extended thinking is assistant-only on the wire, and `lib/` writes four
    # `thinking` and three `redacted_thinking` blocks -- more than it writes
    # `tool_result`. The producer is the same one invariant 5 was added for, one
    # block type over: a strategy echoing a span that contains an assistant turn
    # with extended thinking puts a `thinking` block into the fixed-`user`
    # replacement.
    it "refuses a thinking block in a user message" do
      messages = [user(text("hi")), user({ "type" => "thinking", "thinking" => "hmm", "signature" => "s" })]

      found = violation(messages, :misplaced_block)

      expect(found.positions).to eq([1])
      expect(found.message).to include("thinking", "assistant")
    end

    it "refuses a redacted_thinking block in a user message" do
      messages = [user(text("hi")), user({ "type" => "redacted_thinking", "data" => "opaque" })]

      expect(violation(messages, :misplaced_block).message).to include("redacted_thinking", "assistant")
    end

    it "permits both thinking kinds in an assistant message, which is where they belong" do
      messages = [user(text("hi")),
                  assistant({ "type" => "thinking", "thinking" => "hmm", "signature" => "s" },
                            { "type" => "redacted_thinking", "data" => "opaque" }, text("done"))]

      expect(described_class.new(messages).violations).to be_empty
    end

    it "says nothing about a text block, which any role may carry" do
      messages = [user(text("hi")), assistant(text("ok")), user(text("more"))]

      expect(described_class.new(messages).violations).to be_empty
    end
  end

  describe "tool pairing" do
    it "refuses a tool_use with no answering tool_result, naming the id" do
      messages = [user(text("hi")), assistant(tool_use("toolu_0")), assistant(text("never answered"))]

      found = violation(messages, :unanswered_tool_use)

      expect(found.positions).to eq([1])
      expect(found.message).to include("toolu_0")
    end

    it "refuses a tool_result whose tool_use_id appears nowhere, naming the orphan" do
      messages = [user(text("hi")), assistant(text("ok")), user(tool_result("toolu_ghost"))]

      found = violation(messages, :orphaned_tool_result)

      expect(found.positions).to eq([2])
      expect(found.message).to include("toolu_ghost")
    end

    it "refuses a pair split by an intervening message, naming the separation" do
      messages = [
        user(text("hi")),
        assistant(tool_use("toolu_0")),
        user(text("wait")),
        user(tool_result("toolu_0"))
      ]

      found = violation(messages, :split_tool_pair)

      expect(found.positions).to eq([1, 3])
      expect(found.message).to include("toolu_0", "1", "3")
      expect(described_class.new(messages).violations.map(&:rule)).to eq([:split_tool_pair])
    end

    # Finding 4: the invariant is "an answering tool_result in the immediately
    # following message AND VICE VERSA", but the result side only ever asked
    # whether the id appeared SOMEWHERE among the uses. De-duplicating the
    # split report onto the tool_use side had silently deleted the other half.
    it "refuses a second tool_result for an already-answered id, far from its tool_use" do
      messages = [
        user(text("go")),
        assistant(tool_use("a")),
        user(tool_result("a")),
        assistant(text("x")),
        user(tool_result("a"))
      ]

      found = violation(messages, :orphaned_tool_result)

      expect(found.positions).to eq([4])
    end

    it "refuses a tool_result that precedes its own tool_use" do
      messages = [user(tool_result("a")), assistant(tool_use("a")), user(text("hi"))]

      expect(violation(messages, :split_tool_pair).positions).to eq([0, 1])
    end

    # Finding 8, first half: a pair in ONE message is not "answered in
    # messages[1], not the message after it", and its positions are [1], not
    # [1, 1]. NIT 3: nor is it "at [1] and at [1], not consecutive" -- the same
    # self-contradiction in Array clothing. It never spans two messages at all.
    it "names a tool_use and tool_result sharing one message without repeating the position" do
      found = violation([user(text("go")), assistant(tool_use("a"), tool_result("a"))], :split_tool_pair)

      expect(found.positions).to eq([1])
      expect(found.message).to include("share messages[1]")
      expect(found.message).not_to include("consecutive")
    end

    # Finding 8, second half: the second use of a duplicated id is answered by
    # nothing -- calling that a split pair undercuts the reason three rules
    # exist. Pairing is positional, so the one tool_result belongs to the use
    # it is adjacent to.
    it "calls the unanswered second use of a duplicated id unanswered, not split" do
      messages = [
        user(text("go")),
        assistant(tool_use("a")),
        user(tool_result("a")),
        assistant(tool_use("a")),
        user(text("end"))
      ]

      expect(described_class.new(messages).violations.map(&:rule)).to eq([:unanswered_tool_use])
      expect(violation(messages, :unanswered_tool_use).positions).to eq([3])
    end

    # NIT 5: the id is load-bearing data for anything that groups or dedupes
    # violations -- a derivation audit does exactly that -- so it must not live
    # only in the prose. Two splits for different ids are otherwise identical
    # in every machine-readable member.
    it "distinguishes two split pairs by their subject, not only by their sentence" do
      messages = [
        user(text("go")),
        assistant(tool_use("a"), tool_use("b")),
        user(text("wait")),
        user(tool_result("a"), tool_result("b"))
      ]

      found = described_class.new(messages).violations

      expect(found.map(&:positions)).to eq([[1, 3], [1, 3]])
      expect(found.map(&:subject)).to eq(%w[a b])
      expect(found.map { |one| [one.rule, one.positions, one.subject] }.uniq.size).to eq(2)
    end

    it "carries the id as the subject of every rule that is about one" do
      expect(violation([user(text("hi")), assistant(tool_use("t"))], :unanswered_tool_use).subject).to eq("t")
      expect(violation([user(tool_result("g")), assistant(text("x"))], :orphaned_tool_result).subject).to eq("g")
    end

    # Ruling 2, ported from probe_t1_tool_pairs.rb. A block carrying neither
    # key yielded a nil id on both sides, and `nil == nil` reported an id-less
    # tool_use and an id-less tool_result as a MATCHED pair -- the validator
    # passing an array the wire refuses, which is its only job. Asking whether
    # a key is absent is not reading a fourth key.
    it "refuses a tool_use carrying no id" do
      messages = [user(text("go")), assistant({ "type" => "tool_use", "name" => "read" }), user(text("hi"))]

      found = violation(messages, :missing_tool_id)

      expect(found.positions).to eq([1])
      expect(found.message).to include("tool_use", "id")
    end

    it "refuses a tool_result carrying no tool_use_id" do
      messages = [user(text("go")), assistant(tool_use("a")), user({ "type" => "tool_result", "content" => "ok" })]

      found = violation(messages, :missing_tool_id)

      expect(found.positions).to eq([2])
      expect(found.message).to include("tool_result", "tool_use_id")
    end

    it "never pairs one id-less block with another" do
      messages = [
        user(text("go")),
        assistant({ "type" => "tool_use", "name" => "read" }),
        user({ "type" => "tool_result", "content" => "ok" })
      ]

      expect(described_class.new(messages)).not_to be_valid
      expect(described_class.new(messages).violations.map(&:rule)).to eq(%i[missing_tool_id missing_tool_id])
    end

    it "never pairs id-less blocks across two rounds either" do
      messages = [
        user(text("go")),
        assistant({ "type" => "tool_use", "name" => "read" }),
        user({ "type" => "tool_result", "content" => "1" }),
        assistant({ "type" => "tool_use", "name" => "read" }),
        user({ "type" => "tool_result", "content" => "2" })
      ]

      expect(described_class.new(messages).violations.map(&:rule).uniq).to eq([:missing_tool_id])
      expect(described_class.new(messages).violations.size).to eq(4)
    end
  end

  describe "empty content" do
    it "refuses a message whose content array is empty, naming that position" do
      messages = [user(text("hi")), assistant]

      found = violation(messages, :empty_content)

      expect(found.positions).to eq([1])
      expect(found.message).to include("1")
    end
  end

  describe "the empty array" do
    it "is valid rather than a violation" do
      conversation = described_class.new([])

      expect(conversation.violations).to be_empty
      expect(conversation).to be_valid
    end
  end

  # Ported from probe_t1_garbage.rb. The card's contract sentence is that this
  # object REPORTS -- a shape it cannot read is a defect in the array it exists
  # to name, so it must surface as a named violation and never as an exception.
  describe "malformed shapes" do
    let(:garbage) do
      {
        "nil element in the middle" => [user(text("hi")), nil],
        "nil as the only element" => [nil],
        "nil as the first of three" => [nil, user(text("hi")), user(text("ho"))],
        "message is a String" => ["user: hi"],
        "message is an Integer" => [42],
        "message is an Array" => [[{ "role" => "user" }]],
        "message is a Symbol" => [:user],
        "no role key" => [{ "content" => [text("hi")] }],
        "no content key" => [{ "role" => "user" }],
        "role is a Symbol" => [{ "role" => :user, "content" => [text("hi")] }],
        "content is nil" => [{ "role" => "user", "content" => nil }],
        "content is a String" => [{ "role" => "user", "content" => "hi" }],
        "content is a Hash" => [{ "role" => "user", "content" => { "type" => "text" } }],
        "content holds raw Strings" => [{ "role" => "user", "content" => %w[hi there] }],
        "content holds nil blocks" => [user(nil)],
        "content holds nested junk" => [user({ "type" => { "deep" => [1, { "a" => nil }] } })],
        "empty hash message" => [{}],
        "messages is not an Array" => { "role" => "user" },
        "messages is nil" => nil
      }
    end

    it "never raises on any of them" do
      garbage.each do |name, input|
        expect { described_class.new(input).violations }.not_to raise_error, name
      end
    end

    it "names a nil element as a malformed message, at its position" do
      found = violation([user(text("hi")), nil], :malformed_message)

      expect(found.positions).to eq([1])
      expect(found.message).to include("1")
    end

    it "names a message that is not a Hash of role and content" do
      expect(violation([42], :malformed_message)).not_to be_nil
      expect(violation([{ "content" => [text("hi")] }], :malformed_message)).not_to be_nil
      expect(violation([{ "role" => "user" }], :malformed_message)).not_to be_nil
    end

    it "names a content entry that is not a block, at its message's position" do
      found = violation([user(text("hi")), assistant(nil)], :malformed_block)

      expect(found.positions).to eq([1])
      expect(found.message).to include("NilClass")
    end

    it "names raw Strings in a content array as malformed blocks" do
      expect(violation([{ "role" => "user", "content" => %w[hi] }], :malformed_block)).not_to be_nil
    end

    it "names an input that is not a message array at all, rather than raising" do
      expect(violation(nil, :malformed_conversation)).not_to be_nil
      expect(violation({ "role" => "user" }, :malformed_conversation).message).to include("Hash")
    end

    # Finding 2: `first.nil?` conflated "no first message" with "a nil first
    # message", which exempted a nil messages[0] from the opening rule outright.
    it "still applies the opening rule when messages[0] is nil, rather than reading it as an empty array" do
      messages = [nil, user(text("hi"))]

      expect(described_class.new(messages).violations.map(&:rule)).to include(:opening_role, :malformed_message)
    end

    it "leaves an unreadable message out of the empty-content rule, which asks about a readable one" do
      expect(described_class.new([nil]).violations.map(&:rule)).not_to include(:empty_content)
    end

    # Finding 9: a bare-String content is a shape the Messages API itself
    # accepts, and no producer in lib/ can emit it -- every `"content" =>` key
    # renders `turn.content`, which is always an Array. Pinned so a future
    # reader meeting this verdict does not go hunting the wrong bug.
    it "reports a bare-String content as empty rather than reading it" do
      expect(described_class.new([{ "role" => "user", "content" => "hi" }]).violations.map(&:rule))
        .to eq([:empty_content])
    end
  end

  # Finding 2: every other pairing example reaches this object through a
  # Conversation, which states its collaborator's contract nowhere -- its
  # keywords, its value shape, and its identity guarantee could all drift with
  # nothing to catch it. It takes occurrences, never messages: that is the seam.
  describe Lain::Context::Conversation::ToolPairs do
    def pairs(uses:, answers:) = described_class.new(uses:, answers:)

    it "takes occurrences rather than messages, and pairs them by position" do
      expect(pairs(uses: [[1, "a"]], answers: [[2, "a"]]).violations).to be_empty
      expect(pairs(uses: [[1, "a"]], answers: [[3, "a"]]).violations.map(&:rule)).to eq([:split_tool_pair])
      expect(pairs(uses: [[1, "a"]], answers: []).violations.map(&:rule)).to eq([:unanswered_tool_use])
      expect(pairs(uses: [], answers: [[2, "a"]]).violations.map(&:rule)).to eq([:orphaned_tool_result])
    end

    it "refuses an occurrence with no id rather than pairing it with another" do
      found = pairs(uses: [[1, nil]], answers: [[2, nil]]).violations

      expect(found.map(&:rule)).to eq(%i[missing_tool_id missing_tool_id])
      expect(found.map(&:subject)).to eq(%w[tool_use tool_result])
    end

    # The guarantee Conversation makes to T5, made here too: one `#violations`
    # must mean one thing, or a caller memoizing one and re-reading the other
    # holds two different promises under one name.
    it "answers a verdict that is stable by identity and shareable, exactly as a Conversation does" do
      paired = pairs(uses: [[1, "a"]], answers: [[3, "a"]])

      expect(paired.violations).to be(paired.violations)
      expect(paired).to be_deeply_frozen
      expect(paired.violations).to be_frozen
    end
  end

  describe "purity" do
    let(:messages) do
      [user(text("hi")), assistant(text("one")), assistant(tool_use("toolu_0")), user(text("orphan-free"))]
    end

    it "agrees with itself across two validations and leaves the input unmutated" do
      before = Lain::Canonical.dump(messages)

      first = described_class.new(messages).violations
      second = described_class.new(messages).violations

      expect(first).to eq(second)
      expect(Lain::Canonical.dump(messages)).to eq(before)
    end

    it "answers the same violations twice from one instance, by identity" do
      conversation = described_class.new(messages)

      expect(conversation.violations).to be(conversation.violations)
    end

    it "is Ractor.shareable?, so a derivation may carry its verdict across the boundary" do
      expect(described_class.new(messages)).to be_deeply_frozen
    end

    it "cannot have its verdict mutated by a caller" do
      expect { described_class.new(messages).violations << :junk }.to raise_error(FrozenError)
    end

    # Ported from probe_t1_purity.rb. Every kind, not two: each rule builds its
    # message down a different interpolation path (`role.inspect`, `id.inspect`,
    # `class`, a position Array's `inspect`), and CLAUDE.md's trap is that
    # interpolation hands back a MUTABLE String. A sweep is the only version of
    # this example that pins what it claims to.
    describe "every violation kind" do
      let(:by_rule) do
        {
          malformed_conversation: nil,
          malformed_message: [nil],
          malformed_block: [user(text("hi")), assistant(nil)],
          opening_role: [assistant(text("summary")), user(text("hi"))],
          alternation: [user(text("hi")), assistant(text("a")), assistant(text("b"))],
          unanswered_tool_use: [user(text("hi")), assistant(tool_use("toolu_0")), user(text("nope"))],
          orphaned_tool_result: [user(text("hi")), assistant(text("a")), user(tool_result("toolu_ghost"))],
          split_tool_pair: [user(text("hi")), assistant(tool_use("t")), user(text("wait")), user(tool_result("t"))],
          missing_tool_id: [user(text("hi")), assistant({ "type" => "tool_use", "name" => "read" })],
          misplaced_block: [user(text("hi")), user(tool_use("t")), user(tool_result("t"))],
          empty_content: [user(text("hi")), assistant]
        }
      end

      it "is produced by the array that provokes it" do
        by_rule.each do |rule, input|
          expect(described_class.new(input).violations.map(&:rule)).to include(rule), rule.to_s
        end
      end

      it "is Ractor.shareable?, positions and message string included" do
        by_rule.each do |rule, input|
          found = described_class.new(input).violations.find { |candidate| candidate.rule == rule }

          expect(found).to be_deeply_frozen, rule.to_s
          expect(found.positions).to be_frozen, rule.to_s
          expect(found.message).to be_frozen, rule.to_s
        end
      end
    end
  end
end
