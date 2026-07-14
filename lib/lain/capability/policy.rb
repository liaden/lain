# frozen_string_literal: true

module Lain
  module Capability
    # Resolves what a requirer `#requires` against what a provider `#supports?`,
    # under one of two named policies. The two policies share the resolution --
    # find the required capabilities the provider lacks -- and differ only in what
    # they do about a missing one, which is exactly a strategy split: {Strict}
    # raises (reusing {Provider#require!}, so the error and its message stay in one
    # place); {Degrade} no-ops but LOUDLY, journaling one {Event::CapabilityDegraded}
    # per missing capability so the no-op is a durable record rather than a silent
    # divergence.
    #
    # The journal is injected and defaults to a {Channel::Null}, so no code path
    # ever guards `if journal`. Both a real {Journal} and a {Channel} answer `<<`,
    # so either can receive the attributed event.
    #
    # Every {#resolve} returns the run's {DegradedSet} -- empty under `:strict`
    # (it would have raised otherwise) and under `:degrade` when nothing was
    # missing.
    class Policy
      # @return [Array<Symbol>] the policy names {.for} accepts
      NAMES = %i[strict degrade].freeze

      # @param name [Symbol] one of {NAMES}
      # @param journal [#<<] where a degradation record is pushed; a Null channel
      #   by default
      # @return [Policy]
      # @raise [ArgumentError] on an unknown policy name (unknown values fail loudly)
      def self.for(name, journal: Channel::Null.instance)
        strategy = STRATEGIES[name]
        # Not `validates :strategy, presence: true`: this is a FACTORY mapping a
        # name to a strategy class, and Policy has no `strategy` attribute to
        # validate. Validate-then-freeze (T6) governs a value object's OWN
        # construction; a lookup that rejects an unknown key is a different shape.
        # The explicit raise also NAMES the valid options (NAMES), which a bare
        # presence error cannot -- so it is kept, more diagnostic, not less.
        if strategy.nil?
          raise ArgumentError,
                "unknown capability policy #{name.inspect}, expected one of #{NAMES.inspect}"
        end

        strategy.new(journal: journal)
      end

      def initialize(journal: Channel::Null.instance)
        @journal = journal
      end

      # @param requirer [#requires] a Context combinator
      # @param provider [#supports?, #require!]
      # @return [DegradedSet] the capabilities that degraded on this run
      def resolve(requirer, provider)
        # Normalize and dedup FIRST: a combinator that concatenates its parts'
        # `#requires` can yield the same capability twice, and the "exactly one
        # degradation per missing capability" invariant must hold over the
        # capability, not over how many times it was asked for.
        required = requirer.requires.map(&:to_sym).uniq
        missing = required.reject { |capability| provider.supports?(capability) }
        missing.each { |capability| handle_missing(capability, requirer, provider) }
        DegradedSet.new(missing)
      end

      private

      def handle_missing(_capability, _requirer, _provider)
        raise NotImplementedError, "#{self.class} must implement #handle_missing"
      end

      # `:strict`. A missing capability is an error; reuse the provider's own
      # `require!` so the raised {Provider::Unsupported} and its message live in
      # one place.
      class Strict < Policy
        private

        def handle_missing(capability, _requirer, provider)
          provider.require!(capability)
        end
      end

      # `:degrade`. A missing capability is tolerated but recorded: exactly one
      # attributed event per missing capability, pushed to the injected journal.
      class Degrade < Policy
        private

        def handle_missing(capability, requirer, provider)
          @journal << Event::CapabilityDegraded.new(
            capability: capability,
            requirer: requirer.class.name,
            provider: provider.class.name
          )
        end
      end

      # Defined after the strategies it names: `.for` reads it at call time, so a
      # forward reference from the top of the class body is avoided. Private: an
      # internal lookup table, not part of the surface (`.for` is).
      STRATEGIES = { strict: Strict, degrade: Degrade }.freeze
      private_constant :STRATEGIES
    end
  end
end
