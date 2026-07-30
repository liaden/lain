# frozen_string_literal: true

module Lain
  class Agent
    # The three objects the loop drives -- {ModelCaller}, {ToolRunner},
    # {Accounting} -- resolved from either of the Agent's two construction
    # styles.
    #
    # A caller hands them over WHOLE (`model_caller:`, `tool_runner:`,
    # `accounting:`), or hands over the INGREDIENTS each is built from, which is
    # what every caller did before they were injectable: `provider:` and
    # `model_middleware:`; `handler:`, `tool_middleware:` and `tool_observer:`;
    # `journal:`. Both styles are supported, and they compose ACROSS
    # collaborators -- an injected ToolRunner beside a `provider:` says nothing
    # contradictory. Mixing them for ONE collaborator raises.
    #
    # This is a resolver, not the `Wiring` value object {Agent#initialize}
    # considered and rejected: it holds no run state and it does not move the
    # Agent's public keyword surface -- every keyword is still named on the
    # constructor, so `provider_parity` and the state-machine specs still
    # construct against them. It exists because reconciling two construction
    # styles is a different responsibility from driving a loop, and {Agent} said
    # so by tripping Metrics/ClassLength the moment the rule landed inside it.
    #
    # The refusals fire in a FIXED order -- unknown keyword, explicit nil, double
    # wiring, foreign toolset -- so a call with two mistakes always reports the
    # same one. That order is the vocabulary first (a typo makes every later
    # question meaningless), then the values, then what the values mean together.
    # `MISSING_PROVIDER` is the exception: it fires lazily, while the ModelCaller
    # is being built, so it lands between the last two.
    class Collaborators
      # Each collaborator paired with the legacy keywords that BUILD it when it
      # is not injected. Read two ways: the defaulting table, and the clash
      # table {#refuse_double_wiring} consults.
      INGREDIENTS = { model_caller: %i[provider model_middleware],
                      tool_runner: %i[handler tool_middleware tool_observer],
                      accounting: %i[journal] }.freeze

      # "No keyword was written here" -- which `nil` cannot say, because an
      # explicit nil is a caller MISTAKE this class refuses
      # ({#refuse_explicit_nil}) and the two have to be told apart. A bare frozen
      # object, so nothing a caller could plausibly pass collides with it. It is
      # the default of every wiring keyword on {Agent#initialize} as well as
      # here, which is the only reason it is public.
      OMITTED = Object.new.freeze

      MISSING_PROVIDER = "no provider: and no model_caller: -- the Agent needs something to call. Pass either the " \
                         "provider (and a ModelCaller gets built over it) or a ModelCaller of your own."
      private_constant :MISSING_PROVIDER

      attr_reader :model_caller, :tool_runner, :accounting

      # Resolved eagerly, so a wiring mistake is an error at construction rather
      # than on the first turn.
      #
      # @param toolset [Lain::Toolset] the run's capability set. Shared, not an
      #   ingredient: the Agent renders it and the ToolRunner harvests answered
      #   questions from it, so naming it beside `tool_runner:` is not a clash --
      #   it is REQUIRED to agree with the runner's own ({#refuse_foreign_toolset}).
      def initialize(toolset:, model_caller: OMITTED, tool_runner: OMITTED, accounting: OMITTED, **ingredients)
        @toolset = toolset
        refuse_unknown(ingredients.keys)
        refuse_explicit_nil({ model_caller:, tool_runner:, accounting:, **ingredients })
        @given = written(ingredients)
        resolve(written({ model_caller:, tool_runner:, accounting: }))
      end

      private

      # The keys a caller actually wrote. Every wiring keyword defaults to
      # {OMITTED}, so anything still holding it was never written -- and unlike a
      # `compact`, this keeps an explicit nil visible for the check above.
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
      # police its own vocabulary. A key the table does not carry is a typo, and
      # swallowing it would drop the wiring it was meant to say. Asked of the RAW
      # keys, before anything is discarded: a typo whose value happens to be nil
      # is still a typo.
      def refuse_unknown(keys)
        unknown = keys - INGREDIENTS.values.flatten
        return if unknown.empty?

        raise ArgumentError, "unknown ingredient: #{labelled(unknown)}. The wiring keywords are " \
                             "#{labelled(INGREDIENTS.keys + INGREDIENTS.values.flatten)}."
      end

      # An explicit nil is a mistake, not a request for the default: the way to
      # take a default is to OMIT the keyword. Loud, because every silent reading
      # is worse than an error. `handler: nil` used to propagate and crash on
      # dispatch; read as a default it would quietly become a LIVE
      # {Effect::Handler::Live} over the real toolset -- a nil that runs tools.
      # `journal: nil` would quietly become the Null channel and discard the
      # experiment record a caller thought they had asked for. cli/tool_guard.rb
      # takes the same position on the same shape.
      def refuse_explicit_nil(wiring)
        nils = wiring.select { |_key, value| value.nil? }.keys
        return if nils.empty?

        raise ArgumentError, "#{labelled(nils)} was given as nil. Omit the keyword to take the default; nil is " \
                             "not a wiring value, and reading it as one would hide the mistake."
      end

      # Both construction styles are valid; mixing them for ONE collaborator is
      # not. A caller who hands over a {ModelCaller} *and* a `provider:` has
      # stated two answers to "which provider does this run talk to", and
      # quietly honouring one of them is how a bench arm measures an arm nobody
      # configured. Loud, at construction, naming both halves.
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
      # capability set writes a DIFFERENT Timeline for the same conversation.
      # `Canonical` bytes serve turn hashing and prompt-cache stability both, so
      # the symptom would be an unexplained cache miss and never an error. A
      # default-built runner gets the Agent's toolset by construction; an
      # injected one is the caller's, and identity is the honest test, because the
      # harvest drains per-INSTANCE state (`take_answered_questions` empties its
      # queue) and two equal toolsets holding different tool objects would
      # harvest from the wrong ones.
      def refuse_foreign_toolset
        refuse_mute_runner
        return if @tool_runner.toolset.equal?(@toolset)

        raise ArgumentError, "tool_runner: was built over a different Toolset than toolset:. The runner harvests " \
                             "answered questions from its own toolset and the Agent commits them as the turn's " \
                             "causal_parents, so two sets means two digests for one conversation. Build it as " \
                             "ToolRunner.new(handler:, toolset:) with that same Toolset, or omit tool_runner:."
      end

      # The gate above sends one message, so a runner that cannot answer it is
      # refused by name. This seam exists for duck-typed runners -- depend on
      # messages, not on types -- and a bare NoMethodError from inside the
      # resolver would be the one crash among refusals that all say what to do.
      def refuse_mute_runner
        return if @tool_runner.respond_to?(:toolset)

        raise ArgumentError, "tool_runner: does not answer #toolset, so there is no way to check that it harvests " \
                             "from the same capabilities the model is shown. A stand-in for #{ToolRunner} has to " \
                             "expose the toolset its answered-question harvest reads."
      end

      # The legacy style's named defaults, each resolved once, here. `fetch` with
      # a block keeps the Null-Object posture: the default is named at the one
      # place that needs it, so nothing downstream ever tolerates a nil.
      def built_model_caller
        ModelCaller.new(provider: @given.fetch(:provider) { raise ArgumentError, MISSING_PROVIDER },
                        middleware: @given.fetch(:model_middleware) { Middleware::Stack.new })
      end

      def built_tool_runner
        ToolRunner.new(handler: @given.fetch(:handler) { Effect::Handler::Live.new(toolset: @toolset) },
                       middleware: @given.fetch(:tool_middleware) { Middleware::Stack.new },
                       toolset: @toolset,
                       observer: @given.fetch(:tool_observer) { ToolRunner::Observer::Null.new })
      end

      def built_accounting = Accounting.new(journal: @given.fetch(:journal) { Channel::Null.instance })

      def labelled(keywords) = keywords.map { |keyword| "#{keyword}:" }.join(", ")
    end
  end
end
