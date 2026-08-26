# frozen_string_literal: true

module Lain
  class Agent
    # The three objects the loop drives -- {ModelCaller}, {ToolRunner},
    # {Accounting} -- resolved from either of the Agent's two construction
    # styles: handed over WHOLE, or built from the INGREDIENTS named in
    # {INGREDIENTS}, which is what every caller did before they were injectable.
    # The styles compose ACROSS collaborators -- an injected ToolRunner beside a
    # `provider:` says nothing contradictory -- and mixing them for ONE
    # collaborator raises.
    #
    # A resolver, not the `Wiring` value {Agent#initialize} considered and
    # rejected: it holds no run state and moves no keyword off the Agent's
    # constructor, so the parity and state-machine specs still construct against
    # them. It exists because reconciling two construction styles is a different
    # responsibility from driving a loop, and {Agent} said so by tripping
    # Metrics/ClassLength the moment the rule landed inside it.
    #
    # The refusals fire in a FIXED order -- unknown keyword, explicit nil, double
    # wiring, foreign toolset -- so a call with two mistakes always reports the
    # same one: vocabulary first (a typo makes every later question meaningless),
    # then the values, then what the values mean together. `MISSING_PROVIDER` is
    # the exception, firing lazily while the ModelCaller is built, between the
    # last two.
    class Collaborators
      # Each collaborator paired with the legacy keywords that BUILD it when it
      # is not injected: the vocabulary {#refuse_unknown} polices, and the clash
      # table {#refuse_double_wiring} consults. Four of these are
      # {Instrumentation} members too, so their DEFAULTS come from that value;
      # they stay named here because the clash rule is keyed on what a caller
      # actually wrote.
      INGREDIENTS = { model_caller: %i[provider model_middleware],
                      tool_runner: %i[handler tool_middleware tool_observer],
                      accounting: %i[journal] }.freeze

      # The ingredient vocabulary, flat. Public because {Agent} splits its own
      # `**instrumented` splat on it: three {Instrumentation} members build no
      # collaborator, so forwarding them here would read as typos.
      KEYWORDS = INGREDIENTS.values.flatten.freeze

      # "No keyword was written here" -- which `nil` cannot say, because an
      # explicit nil is a caller MISTAKE this class refuses
      # ({#refuse_explicit_nil}). A bare frozen object, so nothing a caller could
      # plausibly pass collides with it. Public only because it is the default of
      # every wiring keyword on {Agent#initialize} too.
      OMITTED = Object.new.freeze

      MISSING_PROVIDER = "no provider: and no model_caller: -- the Agent needs something to call. Pass either the " \
                         "provider (and a ModelCaller gets built over it) or a ModelCaller of your own."
      private_constant :MISSING_PROVIDER

      attr_reader :model_caller, :tool_runner, :accounting

      # Resolved eagerly, so a wiring mistake is an error at construction rather
      # than on the first turn.
      #
      # @param toolset [Lain::Toolset] the run's capability set. Shared, not an
      #   ingredient: naming it beside `tool_runner:` is not a clash -- it is
      #   REQUIRED to agree with the runner's own ({#refuse_foreign_toolset}).
      # @param instrumentation [Instrumentation] where a default-built
      #   collaborator reports. Defaults to the all-Null value.
      # @param model_caller [ModelCaller] handed over whole, or {OMITTED} when
      #   the caller supplies `provider:`/`model_middleware:` instead.
      # @param tool_runner [ToolRunner] handed over whole, or {OMITTED} when the
      #   caller supplies `handler:`/`tool_middleware:`/`tool_observer:` instead.
      # @param accounting [Accounting] handed over whole, or {OMITTED} when the
      #   caller supplies `journal:` instead.
      # @param ingredients [Hash{Symbol => Object}] the legacy build-from
      #   keywords, resolved into whichever collaborator they belong to
      #   ({INGREDIENTS}); an unknown one is refused ({#refuse_unknown}).
      def initialize(toolset:, instrumentation: Instrumentation.new, model_caller: OMITTED,
                     tool_runner: OMITTED, accounting: OMITTED, **ingredients)
        @toolset = toolset
        @instrumentation = instrumentation
        refuse_unknown(ingredients.keys)
        refuse_explicit_nil({ model_caller:, tool_runner:, accounting:, **ingredients })
        @given = written(ingredients)
        resolve(written({ model_caller:, tool_runner:, accounting: }))
      end

      private

      # The keys a caller actually wrote. Unlike a `compact`, this keeps an
      # explicit nil visible for the check above.
      def written(wiring) = wiring.reject { |_key, value| OMITTED.equal?(value) }

      def resolve(injected)
        refuse_double_wiring(injected)
        @model_caller = injected.fetch(:model_caller) { built_model_caller }
        @tool_runner = injected.fetch(:tool_runner) { built_tool_runner }
        @accounting = injected.fetch(:accounting) { built_accounting }
        refuse_foreign_toolset
      end

      # The ingredients arrive through a splat, so this object -- unlike {Agent},
      # whose every keyword is named and therefore policed by Ruby -- has to
      # police its own vocabulary. Asked of the RAW keys, before anything is
      # discarded: a typo whose value happens to be nil is still a typo.
      def refuse_unknown(keys)
        unknown = keys - KEYWORDS
        return if unknown.empty?

        raise ArgumentError, "unknown ingredient: #{labelled(unknown)}. The wiring keywords are " \
                             "#{labelled(INGREDIENTS.keys + KEYWORDS)}."
      end

      # An explicit nil is a mistake, not a request for the default: the way to
      # take a default is to OMIT the keyword. Loud, because every silent reading
      # is worse -- `handler: nil` read as a default becomes a LIVE
      # {Effect::Handler::Live} over the real toolset, a nil that runs tools, and
      # `journal: nil` would discard the experiment record a caller thought they
      # had asked for. cli/tool_guard.rb takes the same position.
      def refuse_explicit_nil(wiring)
        nils = wiring.select { |_key, value| value.nil? }.keys
        return if nils.empty?

        raise ArgumentError, "#{labelled(nils)} was given as nil. Omit the keyword to take the default; nil is " \
                             "not a wiring value, and reading it as one would hide the mistake."
      end

      # Both styles are valid; mixing them for ONE collaborator is not. A caller
      # who hands over a {ModelCaller} *and* a `provider:` has stated two answers
      # to "which provider does this run talk to", and quietly honouring one is
      # how a bench arm measures an arm nobody configured.
      def refuse_double_wiring(injected)
        injected.each_key do |collaborator|
          refuse_clash(collaborator, INGREDIENTS.fetch(collaborator) & @given.keys)
        end
      end

      def refuse_clash(collaborator, clash)
        return if clash.empty?

        raise ArgumentError, "#{collaborator}: was passed together with #{labelled(clash)}, which is what it " \
                             "would have been BUILT from -- two answers to one wiring question. Pass the " \
                             "collaborator or its ingredients, not both."
      end

      # The digest gate. A {ToolRunner} harvests answered questions from ITS
      # toolset and the {Agent} commits them as the turn's `causal_parents:`,
      # which are Merkle digest input -- so a runner looking at a different
      # capability set writes a DIFFERENT Timeline for the same conversation, and
      # because `Canonical` bytes serve turn hashing and prompt-cache stability
      # both, the symptom is an unexplained cache miss and never an error.
      # Identity, not equality, is the honest test: the harvest drains
      # per-INSTANCE state (`take_answered_questions` empties its queue), so two
      # equal toolsets holding different tool objects would harvest from the
      # wrong ones.
      def refuse_foreign_toolset
        refuse_mute_runner
        return if @tool_runner.toolset.equal?(@toolset)

        raise ArgumentError, "tool_runner: was built over a different Toolset than toolset:. The runner harvests " \
                             "answered questions from its own toolset and the Agent commits them as the turn's " \
                             "causal_parents, so two sets means two digests for one conversation. Build it as " \
                             "ToolRunner.new(handler:, toolset:) with that same Toolset, or omit tool_runner:."
      end

      # The gate above sends one message, so a runner that cannot answer it is
      # refused by name. This seam exists for duck-typed runners, and a bare
      # NoMethodError would be the one crash among refusals that all say what to
      # do.
      def refuse_mute_runner
        return if @tool_runner.respond_to?(:toolset)

        raise ArgumentError, "tool_runner: does not answer #toolset, so there is no way to check that it harvests " \
                             "from the same capabilities the model is shown. A stand-in for #{ToolRunner} has to " \
                             "expose the toolset its answered-question harvest reads."
      end

      # `fetch` with a block keeps the Null-Object posture: the default is named
      # at the one place that needs it, so nothing downstream tolerates a nil.
      # The four reporting keywords fall back to {Instrumentation}'s members
      # rather than to a Null written here, so there is ONE statement of what a
      # run reports through -- the `fetch` stays because a caller resolving
      # collaborators directly may write a keyword without a value.
      def built_model_caller
        ModelCaller.new(provider: @given.fetch(:provider) { raise ArgumentError, MISSING_PROVIDER },
                        middleware: @given.fetch(:model_middleware) { @instrumentation.model_middleware })
      end

      def built_tool_runner
        ToolRunner.new(handler: @given.fetch(:handler) { Effect::Handler::Live.new(toolset: @toolset) },
                       middleware: @given.fetch(:tool_middleware) { @instrumentation.tool_middleware },
                       toolset: @toolset,
                       observer: @given.fetch(:tool_observer) { @instrumentation.tool_observer })
      end

      def built_accounting = Accounting.new(journal: @given.fetch(:journal) { @instrumentation.journal })

      def labelled(keywords) = keywords.map { |keyword| "#{keyword}:" }.join(", ")
    end
  end
end
