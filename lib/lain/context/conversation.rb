# frozen_string_literal: true

module Lain
  class Context
    # A pure predicate over a RENDERED message array: it answers which of the
    # Messages API's structural invariants that array breaks, and nothing else.
    #
    # It REPORTS, it never repairs, and it never raises -- not on an invalid
    # conversation and not on a malformed one. A repairing validator would hide
    # the very defect it exists to name (the shipped compacting render produces
    # an assistant-first, non-alternating request), and a RAISING one would hide
    # it just as well behind a stack trace from whichever rule happened to read
    # the bad shape first. So a shape this object cannot read is itself a named
    # violation. Callers assert validity; {Context::Compact} and the derivation
    # are what get fixed when the assertion fails.
    #
    # Five invariants, each a 400 on the wire:
    #
    # 1. `messages[0]` has role `user`.
    # 2. No two adjacent non-user messages.
    # 3. Every `tool_use` is answered by a `tool_result` in the message
    #    IMMEDIATELY after it, and every `tool_result` answers one immediately
    #    before it.
    # 4. No message has empty content.
    # 5. A block whose type the API binds to a role appears only in a message of
    #    that role: `tool_use`, `thinking` and `redacted_thinking` are
    #    assistant-only, `tool_result` is user-only.
    #
    # == Why invariant 5 is a separate rule from invariant 3
    #
    # Because pairing and placement are independent, and an array can satisfy
    # one perfectly while breaking the other. The producer this was added for is
    # a {Compaction::Derivation} whose strategy ECHOES the blocks of the span it
    # collapsed: a replacement's role is fixed at `user` (with no pins the
    # replacement IS `messages[0]`, which the API requires to be `user`), so an
    # echoed `tool_use` lands in a user message with its `tool_result` still
    # immediately after it. Pairing reports nothing, alternation reports
    # nothing, and the wire returns 400 -- which is the exact class of bug this
    # object exists to catch, found by T5's panel one rule short.
    #
    # == Why adjacent USER messages are legal and adjacent ASSISTANT ones are not
    #
    # Invariant 2 is deliberately not "roles strictly alternate". {Agent}
    # commits ONE user message holding every tool_result of an assistant turn
    # (`Agent#perform_tools`, "Correctness gate 2"), and the human's next ask is
    # the user message right after it -- so `%w[user assistant user user]` is
    # the ordinary shape of a tool round, pinned at `spec/lain/agent_spec.rb`.
    # A rule that refused it would call the Agent's own production output
    # invalid. Two adjacent non-user messages, by contrast, are what a
    # compaction summary injected ahead of an assistant-led tail produces, and
    # nothing in the codebase emits them deliberately.
    #
    # The rule is stated as "neither is a user message" rather than "both are
    # assistant" because this validates a RENDERED array: {Context::Compact}
    # writes its summary's role straight in without {Event.normalize_role}, so
    # the commit layer's closed {Event::ROLES} vocabulary is exactly what cannot
    # be assumed on this side of the seam.
    #
    # == Why it holds its verdict rather than the messages
    #
    # `Ractor.shareable?` is this repo's mechanical statement of "no reachable
    # mutable state", and a rendered message array arrives unfrozen. Retaining
    # it would either forfeit shareability or force a deep freeze of the
    # caller's own array -- a mutation, in an object whose whole promise is that
    # it changes nothing. So construction computes the violations and keeps
    # THOSE; the input is read once and let go.
    class Conversation
      # Which role may carry which block (invariant 5). A block type absent from
      # this map may be carried by any role: counting what `lib/` actually
      # writes, `text` is the whole of that set -- there is no `image` block
      # anywhere in this codebase, and an earlier version of this comment named
      # one.
      #
      # A WHITELIST of the types the API constrains, never a rule inferred from
      # a name. `thinking` and `redacted_thinking` are here because extended
      # thinking is assistant-only on the wire and `lib/` writes seven of them
      # between the two -- more than it writes `tool_result` -- so a strategy
      # echoing a span that contains an assistant turn with extended thinking
      # would otherwise put one into the fixed-`user` replacement and be called
      # valid. That is the same defect as the tool_use one, one block type over.
      #
      # The rule these produce is `:misplaced_block`, renamed from
      # `:misplaced_tool_block` the moment the thinking types arrived. It does
      # not mean "a tool block in the wrong role", it means "a ROLE-RESTRICTED
      # block in the wrong role", and `thinking` is not a tool block by any
      # reading. A violation rule name is INTERFACE -- an audit and a grader key
      # on it -- so a symbol saying `tool` about a thinking block is the
      # name-drifts-from-behaviour failure in the one place it is most
      # expensive. The constant was renamed with it, for the same reason.
      BLOCK_ROLES = { "tool_use" => "assistant", "tool_result" => "user",
                      "thinking" => "assistant", "redacted_thinking" => "assistant" }.freeze

      # `positions` are indices into the message array, so a violation points at
      # the messages rather than describing them -- what T4/T5 need to localize
      # a producer bug. `subject` is the datum the violation is ABOUT (a tool
      # id, an offending role) and exists because that datum must not be
      # readable only out of the prose: two `:split_tool_pair` violations for
      # different ids can carry identical positions, and a derivation audit
      # grouping by `(rule, positions)` would silently fuse them.
      #
      # Data instances are frozen, so freezing the members is all a Violation
      # needs to be shareable.
      Violation = Data.define(:rule, :positions, :subject, :message) do
        # Interpolation hands back a MUTABLE String and an Array literal is
        # unfrozen; either one alone would sink shareability, so every
        # construction goes through here rather than through `.new`.
        #
        # `subject` is rendered to a frozen String rather than stored as it
        # arrived. A wire id IS a String, but a malformed block can carry any
        # object as its "id", and storing that reference would either make the
        # verdict unshareable or force a deep freeze of the caller's block --
        # the mutation this whole object refuses. Rendering copies instead.
        def self.of(rule, positions, message, subject: nil)
          new(rule:, positions: positions.freeze, subject: subject.nil? ? nil : -subject.to_s, message: -message)
        end
      end

      attr_reader :violations

      def initialize(messages)
        @violations = verdict(messages).freeze
        freeze
      end

      def valid? = @violations.empty?

      private

      # A conversation is an Array of rendered messages. Anything else is named
      # rather than coerced: `Array(hash)` would silently turn one bad argument
      # into a plausible-looking two-element conversation.
      def verdict(messages)
        return refusals(messages) if messages.is_a?(Array)

        [Violation.of(:malformed_conversation, [], "a conversation is an Array of messages, got #{messages.class}")]
      end

      def refusals(messages)
        malformed_messages(messages) + malformed_blocks(messages) + opening(messages) +
          alternation(messages) + tool_pairs(messages) + block_roles(messages) + empty_content(messages)
      end

      # Invariant 5. A BLOCK question, so unlike {#tool_pairs} it needs no
      # second object: placement is answered per block against the role of the
      # message carrying it, with nothing to pair and no position arithmetic.
      def block_roles(messages)
        messages.each_with_index.flat_map { |message, index| misplaced(message, index) }
      end

      # The subject is the tool id rather than the block type, for the reason
      # {Violation}'s own doc gives: two misplaced blocks in ONE message would
      # otherwise carry identical rule, positions and subject, and a caller
      # grouping by them would fuse two defects into one. An id-less block
      # answers nil here and is already named by {ToolPairs#anonymous}.
      def misplaced(message, index)
        blocks(message).grep(Hash).filter_map do |block|
          required = BLOCK_ROLES[block["type"]]

          unless required.nil? || role(message) == required
            Violation.of(:misplaced_block, [index],
                         "the #{block["type"]} in messages[#{index}] is carried by a " \
                         "#{role(message).inspect} message; #{block["type"]} blocks are #{required}-only",
                         subject: block["id"] || block["tool_use_id"])
          end
        end
      end

      # `messages.empty?`, not `messages.first.nil?`: those are the same
      # question only in an array that holds no nils, and a nil messages[0] is
      # exactly the case that must NOT be exempted from the opening rule.
      def opening(messages)
        return [] if messages.empty? || user?(messages.first)

        offending = role(messages.first)

        [Violation.of(:opening_role, [0], "messages[0] must have role user, got #{offending.inspect}",
                      subject: offending)]
      end

      def alternation(messages)
        messages.each_cons(2).with_index.select { |pair, _| pair.none? { |message| user?(message) } }.map do |_, index|
          Violation.of(:alternation, [index, index + 1],
                       "neither messages[#{index}] nor messages[#{index + 1}] is a user message")
        end
      end

      # The pairing rule is a separate responsibility over a different value --
      # tool-block occurrences, not messages -- so it is a separate object. This
      # is the only place the two meet: reading the blocks is a message
      # question, pairing them is not.
      def tool_pairs(messages)
        ToolPairs.new(uses: occurrences(messages, "tool_use"),
                      answers: occurrences(messages, "tool_result")).violations
      end

      def malformed_messages(messages)
        messages.each_with_index.reject { |message, _| projection?(message) }.map do |message, index|
          Violation.of(:malformed_message, [index],
                       "messages[#{index}] is not a message of role and content, got #{message.class}")
        end
      end

      # One violation per message, naming the classes it carried instead of
      # blocks -- a content array of twenty junk entries is one defect in one
      # message, not twenty.
      def malformed_blocks(messages)
        messages.each_with_index.filter_map do |message, index|
          junk = blocks(message).grep_v(Hash).map(&:class).uniq

          unless junk.empty?
            Violation.of(:malformed_block, [index],
                         "messages[#{index}] carries content entries that are not blocks: #{junk.join(", ")}")
          end
        end
      end

      # Asked only of a message this object can read: an unreadable one is
      # already named by {#malformed_messages}, and saying "and it is empty" on
      # top of that describes the reader, not the defect.
      #
      # {#opening} and {#alternation} deliberately do NOT abstain on the same
      # message, and the difference is not an inconsistency: position is a
      # property of the ARRAY, so a nil at index 0 is still the wrong opening
      # and a nil between two assistants still breaks the run. Emptiness is a
      # property of the message itself, and there is no message to read.
      def empty_content(messages)
        messages.each_with_index.select { |message, _| readable_and_empty?(message) }.map do |_, index|
          Violation.of(:empty_content, [index], "messages[#{index}] carries no content blocks")
        end
      end

      def readable_and_empty?(message) = projection?(message) && blocks(message).empty?

      # [index, id] for every block of `type`, in message order. A tool_use's
      # own "id" and a tool_result's answering "tool_use_id" are never both on
      # one block, so reading both needs no type branch -- the same single
      # predicate {DedupeToolCalls#stale?} relies on. A missing key yields nil,
      # which {ToolPairs} refuses rather than pairs.
      def occurrences(messages, type)
        messages.each_with_index.flat_map do |message, index|
          blocks(message).grep(Hash)
                         .select { |block| block["type"] == type }
                         .map { |block| [index, block["id"] || block["tool_use_id"]] }
        end
      end

      # A message whose content is not a list contributes no blocks, so a shape
      # this object cannot read is NAMED by a rule rather than raising out of
      # one that was not asking about shape. A bare String content -- a shape
      # the Messages API itself accepts -- therefore reports as
      # `:empty_content`. That is unreachable from `lib/`: every producer of a
      # `"content" =>` key renders `turn.content`, which is always an Array.
      def blocks(message)
        content = projection?(message) ? message["content"] : nil
        content.is_a?(Array) ? content : []
      end

      # {PinnedMessages#projection?}'s check, which is private there: the
      # pipeline primitive is a Hash carrying "role" and "content". Every
      # reader here is gated on it, which is what makes "reports, never raises"
      # a property of the object rather than a hope about its input.
      def projection?(message)
        message.is_a?(Hash) && message.key?("role") && message.key?("content")
      end

      def role(message) = projection?(message) ? message["role"] : nil

      def user?(message) = projection?(message) && MessageEnvelope.wrap(message).user?

      # The tool_use/tool_result pairing rule, over the occurrences a
      # conversation read out of its messages: `[message index, id]` pairs. It
      # never sees a message -- reading blocks out of messages is a message
      # question, pairing them is not -- which is why it is its own object and
      # its own value.
      #
      # Pairing is POSITIONAL: a tool_use at `i` is answered by a tool_result
      # for its id at `i + 1`, and a tool_result at `j` answers a tool_use at
      # `j - 1`. Both DIRECTIONS are asked, which is what stops a second
      # tool_result for an already-answered id from sailing through. What is
      # left LOOSE on each side then classifies the rest, and that is what makes
      # the second use of a duplicated id "unanswered" (the single answer is
      # already adjacent to the first use) rather than "split".
      #
      # == Scope: positions, not multiplicities
      #
      # The match is by SET MEMBERSHIP at a position, not by count: an id is
      # answered if a tool_result for it sits at `i + 1`, however many blocks
      # carry that id. So two same-id `tool_use` blocks in ONE message answered
      # by a single tool_result report nothing, and a counting reading of
      # invariant 3 would call that a defect. That is a deliberate limit, not an
      # oversight: matching by multiplicity means consuming answers pairwise,
      # and nothing in `lib/` emits a duplicated tool id inside one message --
      # `ToolRunner` mints one id per call. A follow-up covers the counting
      # rule; T5 carries an escalation trigger for the day a derivation can
      # produce that shape.
      class ToolPairs
        attr_reader :violations

        # Computed once and retained INSTEAD of the occurrences, for the same
        # reason {Conversation} keeps only its verdict: one `#violations` here
        # and one there must mean the same thing -- stable by identity, and a
        # shareable value -- or a caller that memoized one and re-read the other
        # is holding two different promises under one name.
        def initialize(uses:, answers:)
          @violations = refusals(uses, answers).freeze
          freeze
        end

        private

        def refusals(uses, answers)
          loose_uses = loose(uses, answers, 1)
          loose_answers = loose(answers, uses, -1)

          anonymous(uses, "tool_use", "id") + anonymous(answers, "tool_result", "tool_use_id") +
            unanswered(loose_uses, loose_answers) + orphaned(loose_answers, loose_uses) +
            separated(loose_uses, loose_answers)
        end

        # Occurrences with no counterpart at the adjacent position. The id
        # lookup goes through a position map rather than an `Array#include?`
        # per occurrence, which is what keeps validating a long derived chain
        # linear in its length.
        def loose(occurrences, counterparts, step)
          at = positions_by_id(counterparts)

          identified(occurrences).reject { |(index, id)| at.fetch(id, []).include?(index + step) }
        end

        # A tool block carrying neither key yields a nil id, and `nil == nil`
        # would report an id-less tool_use and an id-less tool_result as a
        # MATCHED pair -- an array the wire refuses, passed by the object whose
        # only job is to refuse it. So an id-less block is a violation in its
        # own right and never reaches the pairing. Asking whether a key is
        # ABSENT reads no key beyond the three a tool block may be read for.
        def anonymous(occurrences, type, key)
          occurrences.select { |(_, id)| id.nil? }.map do |(index, _)|
            Violation.of(:missing_tool_id, [index], "the #{type} in messages[#{index}] carries no #{key.inspect}",
                         subject: type)
          end
        end

        def identified(occurrences) = occurrences.reject { |(_, id)| id.nil? }

        def unanswered(loose_uses, loose_answers)
          elsewhere = positions_by_id(loose_answers)

          loose_uses.reject { |(_, id)| elsewhere.key?(id) }.map do |(index, id)|
            Violation.of(:unanswered_tool_use, [index],
                         "the tool_use #{id.inspect} in messages[#{index}] is never answered", subject: id)
          end
        end

        def orphaned(loose_answers, loose_uses)
          elsewhere = positions_by_id(loose_uses)

          loose_answers.reject { |(_, id)| elsewhere.key?(id) }.map do |(index, id)|
            Violation.of(:orphaned_tool_result, [index],
                         "the tool_result #{id.inspect} in messages[#{index}] answers no tool_use before it",
                         subject: id)
          end
        end

        # Both halves present, neither adjacent to the other. Reported ONCE per
        # id rather than from both sides, naming every loose position on both --
        # so a pair sharing one message is one position, not the same index
        # twice.
        def separated(loose_uses, loose_answers)
          at_use = positions_by_id(loose_uses)
          at_answer = positions_by_id(loose_answers)

          (at_use.keys & at_answer.keys).map { |id| split(id, at_use.fetch(id), at_answer.fetch(id)) }
        end

        def split(id, uses, answers)
          Violation.of(:split_tool_pair, (uses + answers).uniq.sort, split_message(id, uses, answers), subject: id)
        end

        # A pair sharing ONE message is not "at [1] and at [1], not consecutive"
        # -- that sentence contradicts itself. It is a pair that never spans two
        # messages at all, and it says so.
        def split_message(id, uses, answers)
          positions = (uses + answers).uniq

          if positions.one?
            "the tool_use #{id.inspect} and its tool_result share messages[#{positions.first}] " \
              "rather than spanning two messages"
          else
            "the tool_use #{id.inspect} at #{uses.inspect} and its tool_result at " \
              "#{answers.inspect} are not in consecutive messages"
          end
        end

        def positions_by_id(occurrences)
          occurrences.group_by(&:last).transform_values { |found| found.map(&:first) }
        end
      end
    end
  end
end
