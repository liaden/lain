# frozen_string_literal: true

module Lain
  class Context
    # The session's pin-set, wearing {ProtectedPatterns}' duck: a String in, a
    # Boolean out, so the four combinators that consult a protection policy take
    # one without a signature changing anywhere.
    #
    # It is NOT a ProtectedPatterns holding the dumps as patterns. That class
    # `Regexp.escape`s a String into a SUBSTRING match, so pinning one message
    # would also protect every longer message containing its bytes -- and a
    # tool_result re-sent inside a bigger turn is ordinary. A pin names one
    # message exactly, which is set membership over whole canonical dumps.
    #
    # A DIGEST IS NOT A DUMP. A pin is recorded as a turn digest
    # ({Session#pins}), and a turn's content address folds `meta` and
    # `causal_parents` that the projected message never carries. A set built out
    # of digests would be a well-formed set of Strings that misses EVERY lookup,
    # silently and permanently. So this object takes MESSAGES and derives the
    # bytes itself: there is no spelling of the constructor that accepts the
    # wrong bytes.
    #
    # Two answers, one policy. {#protects?} is what {Compact} asks, per message,
    # about text; {#indices_in} is what {Compaction::Head} asks, once, about
    # positions -- which is how the head excludes the pinned span WITHOUT
    # dumping a message per turn on the every-turn render path. Both read the
    # same set, so the head and the Compact cannot name different messages.
    #
    # {#indices_in} answers every BYTE-IDENTICAL position, not only the one whose
    # turn was pinned: Compact can only ever see text, so it protects both
    # occurrences of a repeated tool result once either is pinned, and a head
    # naming only one would be measuring bytes no compaction will reclaim.
    #
    # A `tool_use`/`tool_result` pair is protected TOGETHER or not at all, and
    # the pairing is read off `candidates` -- the WHOLE chain being rendered,
    # not only what was literally pinned. {Lain::CLI::Command::Pin} still
    # drags a turn's counterpart into the pin-set at pin time (so replay stays
    # explicit and `/unpin` finds both), but that write-time drag cannot
    # protect a turn pinned while its `tool_use` was still PARKED -- there was
    # nothing to drag yet. Closing over `candidates` at construction is what
    # protects that turn anyway once the answer lands: the next render hands
    # this object the full chain, the counterpart is found there, and both
    # protect together -- with no re-pin, and no different behaviour for an
    # old session file whose record names only one digest of a pair. A half is
    # dropped only when its counterpart is genuinely absent from `candidates`,
    # which for a live render means still-parked at the head -- not
    # compactable anyway.
    class PinnedMessages
      # @param messages [Array<Hash>] the PROJECTED messages of the pinned
      #   turns, as {Context#render} builds them. Only read -- a deeply frozen
      #   copy is taken, so a later mutation of the caller's message cannot move
      #   this policy.
      # @param candidates [Array<Hash>] every message on the chain a pinned
      #   half's counterpart may be found in -- {Compaction::Source} hands this
      #   the turn's whole walk. Defaults to `messages` itself, so a caller with
      #   no wider chain to offer (this file's own unit specs, and every other
      #   `PinnedMessages.new` site) still pairs within whatever it pinned,
      #   exactly as before this parameter existed.
      def initialize(messages = [], candidates: messages)
        pinned = messages.map { |message| canonical(message) }.freeze
        pool = candidates.map { |message| canonical(message) }.freeze
        kept = matched(pinned, pool)
        @projections = kept.to_set.freeze
        @dumps = kept.to_set { |message| -Canonical.dump(message) }.freeze
        freeze
      end

      # {ProtectedPatterns}' duck.
      #
      # @param text [String] the canonical dump of one candidate message
      # @return [Boolean]
      def protects?(text) = @dumps.include?(text)

      # Lets a consumer skip the exemption pass entirely, exactly as
      # {ProtectedPatterns#none?} does.
      def none? = @dumps.empty?

      # Which of `messages` this policy protects, positionally.
      #
      # Structural equality, never a dump: {Compaction::Head} runs on EVERY turn
      # including the deferring ones, and a `Canonical.dump` per message there is
      # a per-turn cost the head does not otherwise pay. An unpinned session
      # pays nothing at all -- there is no set to look in.
      #
      # PRECONDITION, load-bearing: `messages` are CANONICAL-NORMALIZED
      # projections. `Hash#eql?` distinguishes `{"type" => …}` from `{type: …}`
      # while {#protects?}'s canonical dumps deliberately collapse them, so a
      # candidate that dumps equal to a pin without being `eql?` to it would be
      # protected by {Context::Compact} and named by the head -- the over-report
      # both were changed to delete. Pins are canonicalized at construction, so
      # only CANDIDATES can violate this, and nothing reaches it through
      # {Compaction::Source} (an Event's body is normalized at commit). Stated
      # rather than checked, because checking it per candidate is exactly the
      # per-message dump this method exists to avoid.
      #
      # @param messages [Array<Hash>] canonical-normalized projected messages,
      #   in order
      # @return [Set<Integer>]
      def indices_in(messages)
        return NO_POSITIONS if none?

        messages.each_index.select { |index| @projections.include?(messages[index]) }.to_set.freeze
      end

      private

      NO_POSITIONS = Set.new.freeze
      private_constant :NO_POSITIONS

      # Guard FIRST, canonicalize second. The guard is what keeps a digest --
      # or a Symbol-keyed Hash that is not a projection at all -- out of the
      # set, and normalizing first would rewrite `{role:, content:}` into
      # something it accepts.
      #
      # Canonicalizing is what keeps {#protects?} and {#indices_in} reading the
      # SAME equivalence relation. `Canonical` collapses Symbol keys onto String
      # keys and `Hash#eql?` does not, so a pin carrying Symbol keys inside its
      # content dumps one way and hashes another: Compact protects the message,
      # the head names it anyway, and the over-report is back. Paid once per pin,
      # never per candidate. It also deep-freezes, which is what makes this a
      # snapshot rather than a reference into the caller's Hash.
      def canonical(message)
        raise ArgumentError, "a pin protects a projected message, got #{message.inspect}" unless projection?(message)

        Canonical.normalize(message)
      end

      def projection?(message)
        message.is_a?(Hash) && message.key?("role") && message.key?("content")
      end

      # Which messages actually get protected: an ordinary pinned message
      # always does; a `tool_use`/`tool_result` pinned message does only when
      # every id it names is answered (or asked) SOMEWHERE in `pool`, and when
      # it does, the message `pool` answers with -- the counterpart -- is
      # protected too, pinned or not. The two indices are built from the whole
      # pool once, so no message searches it one id at a time.
      def matched(pinned, pool)
        by_use = index(pool, "tool_use", "id")
        by_result = index(pool, "tool_result", "tool_use_id")
        pinned.flat_map { |message| paired(message, by_use:, by_result:) }.uniq
      end

      def paired(message, by_use:, by_result:)
        used = blocks(message, "tool_use").map { |block| block["id"] }
        return companion(message, used, by_result) if used.any?

        asked = blocks(message, "tool_result").map { |block| block["tool_use_id"] }
        asked.empty? ? [message] : companion(message, asked, by_use)
      end

      # `ids` answered EVERY ONE by `index`, or `message` protects nothing: a
      # `tool_use`/`tool_result` message only PARTLY matched is still a hole,
      # and stranding it alone is the exact defect a pin exists to prevent.
      def companion(message, ids, index)
        return [] unless ids.all? { |id| index.key?(id) }

        [message, *ids.map { |id| index.fetch(id) }]
      end

      def index(pool, type, key)
        pool.each_with_object({}) do |message, found|
          blocks(message, type).each { |block| found[block[key]] = message }
        end
      end

      def blocks(message, type) = message["content"].select { |block| block.is_a?(Hash) && block["type"] == type }
    end

    # The empty policy, the same Null-Object move {ProtectedPatterns::NONE}
    # makes: a Head or a Compact handed this behaves exactly as it did before
    # pins existed, and no caller writes `if pins`.
    PinnedMessages::NONE = PinnedMessages.new.freeze
  end
end
