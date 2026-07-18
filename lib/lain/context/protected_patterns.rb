# frozen_string_literal: true

module Lain
  class Context
    # A shared exempt-span policy: one value, injected into every combinator
    # that can drop or rewrite a span (DedupeToolCalls, PurgeFailedInputs,
    # Prune, Compact), so "never drop THIS" is declared once and honoured
    # everywhere rather than re-implemented per combinator. A plain value
    # object, not a {Combinator} -- it never runs standalone in the `>>`
    # pipeline, it is a policy a combinator CONSULTS about one candidate span
    # at a time.
    #
    # Defaults to {NONE}, which protects nothing: a consumer that never wires
    # this in behaves exactly as it did before the policy existed. That is
    # what keeps Prune's and Compact's existing specs byte-identical after
    # they learned to consult it (see their own files for the exact diff).
    #
    # Patterns are Regexp as-is; a String is treated as a literal substring
    # to protect, via `Regexp.escape`, rather than as regex syntax a caller
    # would have to know to escape themselves.
    class ProtectedPatterns
      def initialize(patterns = [])
        @patterns = Array(patterns).map { |pattern| coerce(pattern) }.freeze
        freeze
      end

      # @param text [String] the candidate span, already reduced to a
      #   comparable String by the caller -- ProtectedPatterns is deliberately
      #   agnostic to whether that String came from a whole message or one
      #   content block, since every consumer's "candidate for removal" is a
      #   different shape (Canonical.dump of either is the idiom every
      #   consumer here uses).
      # @return [Boolean]
      def protects?(text)
        @patterns.any? { |pattern| pattern.match?(text) }
      end

      # Lets a consumer skip the exemption pass entirely (and stay
      # byte-identical to its pre-policy behavior) rather than run a select
      # that can never match anything.
      def none? = @patterns.empty?

      private

      def coerce(pattern) = pattern.is_a?(Regexp) ? pattern : Regexp.new(Regexp.escape(pattern.to_s))
    end

    # The monoid-style default -- matches nothing. Every combinator that
    # takes `protected_patterns:` defaults to this, the same Null-Object move
    # {Sink::Null} makes: no caller ever writes `if protected_patterns`.
    ProtectedPatterns::NONE = ProtectedPatterns.new.freeze
  end
end
