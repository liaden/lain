# frozen_string_literal: true

module Lain
  class Provider
    ModelCapabilities = Data.define(:names, :provenance)

    # What ONE model can do, as the server serving it reports.
    #
    # A server that can be asked about a model answers a set of capability
    # tokens -- ollama's `/api/show` says `["completion", "tools", "thinking",
    # "vision"]` and their kin. Those are facts about the model FILE, not about
    # the endpoint, which is what makes them different from {Provider#capabilities}:
    # thinking sat in one ollama deployment's provider-wide list while the
    # measurements found one server serving models that have it beside models
    # that do not.
    #
    # Nothing here is ollama-specific. The probing is -- {Provider::Ollama#model_capabilities}
    # owns the round trip and the endpoint's shape -- but a reading is a set of
    # names with a provenance, and {#supports?} takes the vocabulary as its
    # argument rather than knowing it.
    #
    # == The third answer
    #
    # A read that never reached a server is {UNKNOWN}, and that is a DIFFERENT
    # answer from a server describing a model whose description omits the
    # capability. Both readings occur for real: an arm that declines to probe
    # answers UNKNOWN for models that genuinely do have the capability.
    #
    # WHICH WAY A CONSUMER MUST FALL ON UNKNOWN IS THE CONSUMER'S POLICY, and it
    # is not decided here -- see planning/specs/chunk-local-models-multimodal-qa.md
    # for the one this chunk ratified. {Support#either} is how a call site states
    # it: three named arms, no predicate, so the policy is readable where it is
    # applied rather than inferred from a docstring one file away.
    class ModelCapabilities
      include Declarative

      # Where the answer came from, and therefore what it may authorise.
      # {UNKNOWN} means nothing was learned -- never that the model said no.
      PROBED = :probed
      UNKNOWN = :unknown
      PROVENANCES = [PROBED, UNKNOWN].freeze

      # `/api/show`'s own key, and its own vocabulary: the tokens {#supports?}
      # takes are the server's rather than {Lain::Provider::CAPABILITIES}. The
      # two overlap at `:thinking` and part at `:vision`, which lain has no
      # provider-wide capability for.
      WIRE_KEY = "capabilities"

      Support = Data.define(:answer)

      # Whether a model has a capability: it has it, the server says it has
      # not, or nobody could say.
      #
      # POLYMORPHIC RATHER THAN PREDICATES, and that is the whole design. A
      # `#supported?`/`#unsupported?` pair leaves the unknown arm falling
      # wherever the call site's boolean happens to send it, invisibly, and a
      # single predicate only hides the choice better -- it is a convention
      # wearing a constraint's clothes. {#either} makes a caller name all three,
      # so a future consumer that must refuse on unknown can say so in the same
      # breath as one that must proceed.
      #
      # `UNKNOWN` here is a {Support}; its enclosing namespace's
      # {ModelCapabilities::UNKNOWN} is a provenance symbol. They say the same
      # thing about two different values.
      class Support
        SUPPORTED = new(answer: :supported)
        UNSUPPORTED = new(answer: :unsupported)
        UNKNOWN = new(answer: :unknown)

        # THREE VALUES AND NEVER A FOURTH, closed after the three exist so they
        # could be built. `Support.new(answer: :banana)` answered every
        # predicate falsely and destructured cleanly -- a fourth answer nothing
        # branches on is the "false in disguise" this whole file refuses.
        private_class_method :new

        # The arms are VALUES, not thunks: this exists to put a policy where a
        # reader sees it, and three literals do that where three lambdas do not.
        # A caller needing lazy work passes callables and calls the result.
        #
        # `fetch` rather than a default, so an answer outside the three raises
        # here instead of silently taking an arm.
        #
        # @param supported [Object] the model has it
        # @param unsupported [Object] the server says it has not
        # @param unknown [Object] nobody could say
        # @return [Object] the arm matching this answer
        def either(supported:, unsupported:, unknown:)
          { supported:, unsupported:, unknown: }.fetch(answer)
        end

        # Closed so {#either} is the only branch. Left public it re-opens
        # `answer == :supported` at a call site, which is the reading this
        # class is shaped to prevent. `Data`'s value equality, `#hash` and
        # `#inspect` read members directly and are unaffected.
        private :answer
      end

      declare do
        attribute :provenance
        validates :provenance,
                  inclusion: { in: PROVENANCES,
                               message: "must be one of #{PROVENANCES.inspect}, got %<value>p" }
      end

      # NAMES ARE SETTLED HERE, not in a factory, because `.new` and `Data#with`
      # are doors too and both were open: an unfrozen Array left
      # `Ractor.shareable?` false, and a bare String passed as `names` turned
      # {#supports?} into `String#include?`, answering SUPPORTED for any
      # substring of a capability name. `Declarative` guards `provenance` alone.
      #
      # Deduplicating `-` rather than `freeze`, so two readings of one server
      # share their strings. A non-String entry is DROPPED rather than coerced:
      # `4.to_s` would put "4" where a capability name goes.
      def initialize(names:, provenance:)
        self.class.check!(provenance:)

        super(names: Array(names).filter_map { |name| -name if name.is_a?(String) }.uniq.freeze, provenance:)
      end

      class << self
        # A body that is not a description, or a description carrying no
        # `capabilities` array, is {NOTHING_KNOWN} rather than an empty reading:
        # an empty reading answers UNSUPPORTED for everything, which is the one
        # thing an unanswered probe must not do.
        #
        # An empty ARRAY is the opposite and is kept: a server that described
        # the model and listed nothing has said something, and a blanket no is
        # the honest reading of it.
        #
        # @param body [Object] whatever the server handed back
        # @return [ModelCapabilities]
        def of(body)
          names = body.is_a?(Hash) ? body[WIRE_KEY] : nil
          names.is_a?(Array) ? probed(names) : NOTHING_KNOWN
        end

        # @param names [Array] the wire's own array
        # @return [ModelCapabilities]
        def probed(names) = new(names:, provenance: PROBED)
      end

      # No server was asked, or none answered.
      NOTHING_KNOWN = new(names: [].freeze, provenance: UNKNOWN)

      # nil is UNKNOWN rather than UNSUPPORTED, in the file whose thesis is that
      # absence of knowledge is never a no: `nil.to_s` matched nothing and read
      # as a refusal, which is the one answer a missing question may not give.
      #
      # @param capability [Symbol, String, nil] one of the server's own tokens
      # @return [Support]
      def supports?(capability)
        return Support::UNKNOWN if capability.nil? || provenance == UNKNOWN

        names.include?(capability.to_s) ? Support::SUPPORTED : Support::UNSUPPORTED
      end
    end
  end
end
