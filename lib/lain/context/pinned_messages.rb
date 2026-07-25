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
    # == A digest is not a dump
    #
    # A pin is recorded as a turn DIGEST ({Session#pins}), and a turn's content
    # address folds `meta` and `causal_parents` that the projected message
    # `{"role" =>, "content" =>}` never carries. A set built out of digests
    # would be a perfectly well-formed set of Strings that misses EVERY lookup,
    # silently and permanently -- the failure {Compaction::SummarySnapshot}'s
    # "ALWAYS BUILD ONE WITH .take" comment describes, where the counts report
    # 0/0 and an empty run looks the same as a broken one. So this object takes
    # MESSAGES and derives the bytes itself, and refuses anything that is not
    # one: there is no spelling of the constructor that accepts the wrong bytes.
    #
    # == Two answers, one policy
    #
    # {#protects?} is what {Compact} asks, per message, about text. {#indices_in}
    # is what {Compaction::Head} asks, once, about positions -- which is how the
    # head excludes the pinned span WITHOUT dumping a message per turn on the
    # every-turn render path. Both read the same set, so the head and the
    # Compact cannot name different messages.
    #
    # {#indices_in} answers every BYTE-IDENTICAL position, not only the one
    # whose turn was pinned. That is not a convenience: Compact can only ever
    # see text, so it protects both occurrences of a repeated tool result once
    # either is pinned, and a head that named only one would be measuring bytes
    # no compaction will reclaim.
    class PinnedMessages
      # @param messages [Array<Hash>] the PROJECTED messages of the pinned
      #   turns, as {Context#render} builds them. Only read -- a deeply frozen
      #   copy is taken, so a later mutation of the caller's message cannot move
      #   this policy.
      def initialize(messages = [])
        pinned = messages.map { |message| canonical(message) }.freeze
        @projections = pinned.to_set.freeze
        @dumps = pinned.to_set { |message| -Canonical.dump(message) }.freeze
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
      # Structural equality, never a dump: {Compaction::Head} runs on EVERY
      # turn including the deferring ones, and a `Canonical.dump` per message
      # there is a per-turn cost the head does not otherwise pay. An unpinned
      # session -- the overwhelming majority -- pays nothing at all, because
      # there is no set to look in.
      #
      # PRECONDITION, and it is load-bearing: `messages` are CANONICAL-NORMALIZED
      # projections. `Hash#eql?` distinguishes `{"type" => …}` from `{type: …}`
      # while {#protects?}'s canonical dumps deliberately collapse them
      # (canonical.rb:18-21), so a candidate that dumps equal to a pin without
      # being `eql?` to it is protected by {Context::Compact} and named by the
      # head -- the over-report both were changed to delete. The pins themselves
      # are canonicalized at construction, so only the CANDIDATES can violate
      # this. Nothing reaches it through {Compaction::Source}: an Event's body is
      # normalized at commit, so every Timeline projection is String-keyed. It is
      # stated rather than checked because checking it per candidate is exactly
      # the per-message dump this method exists to avoid.
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
      # keys (canonical.rb:18-21) and `Hash#eql?` does not, so a pin carrying
      # Symbol keys inside its content dumps one way and hashes another: Compact
      # protects the message, the head names it anyway, and the over-report is
      # back. Paid once per pin, never per candidate. It also deep-freezes,
      # which is what makes this object `Ractor.shareable?` and a snapshot
      # rather than a reference into the caller's Hash.
      def canonical(message)
        raise ArgumentError, "a pin protects a projected message, got #{message.inspect}" unless projection?(message)

        Canonical.normalize(message)
      end

      def projection?(message)
        message.is_a?(Hash) && message.key?("role") && message.key?("content")
      end
    end

    # The empty policy, the same Null-Object move {ProtectedPatterns::NONE}
    # makes: a Head or a Compact handed this behaves exactly as it did before
    # pins existed, and no caller writes `if pins`.
    PinnedMessages::NONE = PinnedMessages.new.freeze
  end
end
