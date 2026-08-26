# frozen_string_literal: true

module Lain
  module CLI
    # Turns `--compact-strategy <name>` into the {Compaction::Strategy::Base}
    # a compacting derivation collapses spans with: which policy, and -- when
    # the policy is model-backed -- which recorded oracle it answers through.
    # {STRATEGIES} is the single authority both the resolution and the flag's
    # help text read. {DEFAULT} is a fallback for a nil ARGUMENT and
    # emphatically not for an unset FLAG; read that constant's own doc first.
    #
    # A STANDALONE class, not a {Backend} method: {Backend} sits at 108 of 110
    # on `Metrics/ClassLength`, so a resolver method there would cross the cop.
    #
    # == A name may be a composition, spelled with `+`
    #
    # `elide-tools+summarize-conversation` resolves each part and folds them
    # with {Compaction::Strategy::Base#|}. That operation is a declared
    # COMMUTATIVE MONOID, so the order the parts are written in is not a
    # semantic, and a one-part name folds to the leaf itself.
    #
    # `+` and not `|` or `,`: `|` is a pipe to every shell an operator would
    # type this into, and `,` reads as "a list of alternatives" where this is a
    # single strategy made of two. Thor treats `+` as an ordinary value
    # character in both `--flag value` and `--flag=value` forms (probed).
    #
    # THE COMPOSITION IS ONLY AS DISJOINT AS ITS PARTS. {Composed} raises
    # `Overlap` from `#propose_ranges`, which needs the messages and the span,
    # and this resolver has neither -- so `elide+summarizing`, two whole-span
    # strategies, CONSTRUCTS here and refuses at the first compacting turn.
    # Refusing that pair here would need a static "claims the whole span"
    # declaration on {Compaction::Strategy::Base}. `elide-tools` and
    # `summarize-conversation` are the pair disjoint by construction: both route
    # their selection through {Compaction::ToolMessages}, so they are exact
    # complements rather than two spellings that happen to agree.
    #
    # == The tier is injected as a factory, never pre-built and never fetched
    #
    # ONE `tier:` CALL PER RESOLUTION, however many oracle-backed parts the
    # name has -- which is what keeps a resumed session reconciling one
    # recorded address per span question instead of one per leaf.
    #
    # Two separate reasons force the factory shape, not one:
    #
    # 1. {Backend#eager} is memoized run state and a second, differing
    #    {Backend#pipeline_source} call raises {Backend::Rebound}, so reaching
    #    into a Backend instance here for its live tier would either double-bind
    #    that memo or silently build a second, disconnected one. The caller
    #    hands its OWN tier-building know-how in, never a Backend reference.
    # 2. {Oracle::Recorded::Journaling} must render its journalled question from
    #    the SAME {Oracle::Definition} the wrapped tier answers through, and
    #    {Compaction::Strategy::Summarizing} owns that definition. A tier built
    #    BEFORE this class knows it is a tier built against a definition nobody
    #    here can see, and the one this class then wraps it with is necessarily
    #    a second, different one -- a false record: the model answers one
    #    question, the journal names another. Taking `tier:` as
    #    `->(definition) { ... }` makes "one definition, two uses" structural.
    #
    #    Structural identity stops at "one object, one expression": nothing here
    #    can ask the tier what definition it answers through ({Oracle::Model}
    #    exposes no `#definition`), so a factory that DISCARDS its argument
    #    still produces the false record silently, one level out. The rule only
    #    the caller can keep: build the tier over the definition you are
    #    handed, not over one of your own.
    #
    # THIS RESOLVER BUILDS THE LIVE PATH ONLY. `tier:` must answer the full
    # {Oracle::Model} duck (`#ask`, `#model`, `#usage`), because
    # {Oracle::Recorded::Journaling} reads all three. A REPLAY tier
    # ({Oracle::Recorded}, `#ask` alone) resolves cleanly and then dies on the
    # render path with an uncontained `NoMethodError` the first time a span
    # collapses -- {Compaction::Strategy::Summarizing#asked} rescues
    # {Lain::Error}, and `NoMethodError` is not one. {#recorded_oracle} refuses
    # that shape at resolve instead; a resume/replay seam belongs directly
    # against {Compaction::Strategy::Summarizing.definition}.
    #
    # THE SUMMARIZING BRANCH'S RETURN MUST NEVER BE REACHABLE FROM ANYTHING
    # HANDED TO `Ractor.make_shareable` ({Scheduler::COMPOSE},
    # {Source::BASE_PROVIDER}): it holds a live oracle and a mutable memo, so
    # it is not, and cannot be made, `Ractor.shareable?`. The two ways that
    # goes wrong are NOT symmetric. The LIVE tier this class builds fails by
    # accident -- {Oracle::Recorded::Journaling}'s default `clock:` is a Proc,
    # and a Proc closing over unshareable `self` is what `make_shareable`
    # actually trips on, so it raises `Ractor::IsolationError`. A Proc-free
    # (resume/replay) graph gives `make_shareable` nothing to object to and
    # freezes SILENTLY, and the NEXT new span dies of an uncontained
    # `FrozenError` on the render path, which is not a {Lain::Error} either.
    # {Compaction::Strategy::Elide} is fully shareable end to end.
    class CompactionStrategy
      # An unrecognized `--compact-strategy` name. Loud and naming the valid
      # set: `--provider` and `--compact-strategy` are different mistakes to
      # make, so the message says which flag was wrong.
      class Unknown < Error; end

      # {STRATEGIES} names a strategy that {#strategy}'s `case` has no branch
      # for -- an internal inconsistency in THIS class, never an operator's
      # flag typo, so deliberately not {Unknown}: that would present a bug in
      # the mapping as a mistake the caller made.
      class Unbuilt < Error; end

      # The summarizing strategy was resolved with no `tier:` factory to
      # build its oracle from. Refused HERE, at resolution, rather than at
      # the first span a strategy is offered -- and addressed to the CALLER
      # of {.resolve}, since no CLI operator can supply a tier factory; only
      # code can.
      class MissingTier < Error; end

      # `tier:` built something that does not answer the full live-tier duck
      # (`#ask`, `#model`, `#usage`) -- most likely a REPLAY tier
      # ({Oracle::Recorded}, `#ask` alone). Refused HERE, naming what is
      # missing, rather than left to crash {Oracle::Recorded::Journaling}'s
      # `#ask` with an uncontained `NoMethodError` at the first span.
      class IncompleteTier < Error; end

      # The strategies `--compact-strategy` selects between, in the order help
      # text lists them: the two whole-span policies first, then the two
      # narrowed ones, the pair a reader is meant to see as complements.
      #
      # The set of LEAVES only -- a name may also be several of these joined by
      # {SEPARATOR}, and the compositions over it are not enumerable.
      STRATEGIES = %w[summarizing elide summarize-conversation elide-tools].freeze

      # What joins two strategy names into one composition. See the class doc
      # for why `+` rather than `|` or `,`, and for what a composition means.
      SEPARATOR = "+"

      # What a nil NAME means to this resolver, and nothing beyond that.
      #
      # IT IS NOT WHAT AN UNSET `--compact-strategy` MEANS. An unset flag means
      # the run's own EAGER tool-result tier -- the control arm every flagged
      # run is measured against -- and {Backend::SpanSummarizer#strategy}
      # short-circuits on nil and never reaches this class at all. They differ
      # in what the chat pays: the eager tier's summaries were already fired
      # off the critical path per tool result, while `summarizing` is a fresh
      # model call per span AT compaction time. So a caller writing
      # `CompactionStrategy.resolve(options[:compact_strategy])` silently gets
      # `summarizing` where the shipped path gets the eager tier. Route an
      # unset flag through {Backend::SpanSummarizer}; reach for this constant
      # only when "no name given" genuinely means "the default policy".
      DEFAULT = "summarizing"

      # @return [Compaction::Strategy::Base] the resolved strategy
      def self.resolve(...) = new(...).strategy

      # @param name [String, nil] the `--compact-strategy` value -- one name
      #   from {STRATEGIES}, or several joined by {SEPARATOR}. nil means
      #   {DEFAULT}, which is NOT what an unset flag means; see that constant.
      # @param tier [#call, nil] a FACTORY, `->(definition) { live tier }`,
      #   that MUST build its tier over the exact `definition` it is handed.
      #   Called at most once PER RESOLUTION -- once for a whole composition,
      #   never once per oracle-backed part -- with
      #   {Compaction::Strategy::Summarizing}'s own {Oracle::Definition}, only
      #   when the resolved name has a model-backed part, and must answer the
      #   full live-tier duck (`#ask`, `#model`, `#usage`). See the class doc.
      # @param sink [Lain::Sink] where {Compaction::Strategy::Summarizing}
      #   reports a tier's failure (a down summarizer leaves a span
      #   uncollapsed rather than dying); the Null sink by default
      # @param journal [#<<] where the wrapped oracle's `oracle_answer`
      #   records land; the Null channel (the default) means nothing is
      #   journalled
      def initialize(name = nil, tier: nil, sink: Sink::Null.new, journal: Channel::Null.instance)
        @name = string_name(name || DEFAULT)
        @tier = tier
        @sink = sink
        @journal = journal
      end

      # One strategy for a plain name, a {Compaction::Strategy::Composed} for a
      # name joined by {SEPARATOR}. `inject(:|)` and not `inject(Identity.new,
      # :|)`: the unit would wrap every single-name resolution in a composition
      # nobody asked for, and the empty case cannot reach here because
      # {#strategy_names} refuses it first.
      #
      # @return [Compaction::Strategy::Base] the resolved strategy
      # @raise [Unknown] on any part outside {STRATEGIES}, including an empty
      #   one
      # @raise [Unbuilt] a name in {STRATEGIES} with no matching branch below
      #   (a bug in this class, not a bad flag)
      # @raise [MissingTier] resolving an oracle-backed part with no `tier:`
      #   given
      # @raise [IncompleteTier] `tier:` built something that does not answer
      #   the full live-tier duck
      def strategy = strategy_names.map { |name| built(name) }.inject(:|)

      private

      # AT THE DOOR, so no path below can hold a non-String `@name`.
      #
      # `String()` would COERCE rather than refuse, and both directions are
      # wrong here: `String(:elide)` answers `"elide"` and resolves cleanly,
      # blessing a caller's type confusion in silence, while `String([1])`
      # answers `"[1]"` and refuses under a garbled name that says nothing
      # about the real mistake.
      #
      # NOT reachable from Thor, which parses a String or nothing. It IS
      # reachable from {Backend}, which reads `@options[:compact_strategy]` out
      # of a Hash a caller may have assembled by hand -- and `Symbol#empty?`
      # EXISTS, so a Symbol used to pass every guard below and die on
      # `Symbol#split` with an uncontained `NoMethodError`. {Unknown} is a
      # {Lain::Error} and `exe/lain` renders it as a clean one-liner; a
      # `NoMethodError` escapes as a backtrace.
      def string_name(name)
        return name if name.is_a?(String)

        raise Unknown, "--compact-strategy takes a String, got #{name.class}: #{name.inspect}; " \
                       "expected one of #{STRATEGIES.inspect}, or several joined by #{SEPARATOR.inspect}"
      end

      def strategy_names = split_name.map { |part| validated(part) }

      # Split with a NEGATIVE limit, so the empty parts survive: plain
      # `"elide+".split("+")` drops the trailing one and would resolve a typo
      # to a bare `elide`, while `"+elide"` refuses -- the same mistake
      # answered two ways depending on which end it was made at. Both refuse
      # now, as {Unknown} naming the empty part.
      #
      # The empty string is Ruby's one exception to that: `"".split("+", -1)`
      # answers `[]` and not `[""]`, whatever the limit, so an empty flag would
      # fold through `inject` to nil and resolve to NO strategy at all --
      # silently, and downstream of every refusal here. Named as the empty part
      # it is instead.
      def split_name = @name.empty? ? [@name] : @name.split(SEPARATOR, -1)

      # Validated once per part, so the mapping below only ever sees a name
      # already known to be in {STRATEGIES}.
      #
      # Names the PART and the VALUE IT CAME FROM, always, and the two differ
      # exactly when the mistake is a separator one. `--compact-strategy
      # elide-tools+` refuses on the empty trailing part, and reporting that as
      # `unknown --compact-strategy ""` is loud and FALSE about what was typed:
      # nobody passed an empty flag, and the next reader goes hunting a
      # shell-quoting bug. For a plain single name the two halves coincide.
      def validated(part)
        return part if STRATEGIES.include?(part)

        raise Unknown, "unknown part #{part.inspect} in --compact-strategy #{@name.inspect}, expected one of " \
                       "#{STRATEGIES.inspect}, or several joined by #{SEPARATOR.inspect}"
      end

      # The leaves. Both oracle-backed branches share {#recorded_oracle}'s one
      # wrap, which is what makes "two strategies, one oracle, one journal"
      # structural rather than a rule a composition has to remember.
      def built(name)
        case name
        when "summarizing" then Compaction::Strategy::Summarizing.new(oracle: recorded_oracle(name), sink: @sink)
        when "elide" then Compaction::Strategy::Elide.new
        when "summarize-conversation"
          Compaction::Strategy::SummarizeConversation.new(oracle: recorded_oracle(name), sink: @sink)
        when "elide-tools" then Compaction::Strategy::ElideToolObservations.new
        else raise Unbuilt, "#{name.inspect} is in STRATEGIES but no branch here builds it"
        end
      end

      # What {Oracle::Recorded::Journaling#ask} reads off its `inner`: the full
      # live-tier duck, {Oracle::Model}'s. A REPLAY tier answers `#ask` alone,
      # which is the shape that used to resolve cleanly and then die on the
      # render path with an uncontained `NoMethodError` -- see {IncompleteTier}.
      LIVE_TIER_DUCK = %i[ask model usage].freeze
      private_constant :LIVE_TIER_DUCK

      # Builds the definition once, then the tier over it, then wraps that tier
      # in {Oracle::Recorded::Journaling} -- never a bare {Oracle::Model} -- so
      # its answers are journalled and a later resume re-derives the same chain
      # from {Oracle::Recorded.from_journal} instead of re-asking a live model.
      #
      # MEMOIZED, so a composition naming two oracle-backed leaves calls
      # `tier:` once and both answer through ONE wrap. Two wraps would put one
      # span's answer on the journal under two oracles and give a resume two
      # addresses to reconcile for one question. It never answers nil, so `||=`
      # cannot memoize a failure.
      #
      # @param part [String] the strategy name that wanted the tier. Named in
      #   the refusal, because more than one oracle-backed name can reach here
      #   and a message hard-coding `summarizing` is wrong for three of the
      #   four things that can.
      def recorded_oracle(part)
        raise MissingTier, "CompactionStrategy.resolve needs tier: to build #{part.inspect}" if @tier.nil?

        @recorded_oracle ||= journaling(Compaction::Strategy::Summarizing.definition)
      end

      def journaling(definition)
        Oracle::Recorded::Journaling.new(inner: live_tier(definition), definition:, journal: @journal)
      end

      # Refuses HERE, naming what is missing, rather than handing
      # {Oracle::Recorded::Journaling} something it will crash on inside
      # `#ask`: refuse before construction, not at the first use.
      def live_tier(definition)
        built = @tier.call(definition)
        missing = LIVE_TIER_DUCK.reject { |message| built.respond_to?(message) }
        return built if missing.empty?

        raise IncompleteTier, "tier: built a #{built.class}, which does not answer " \
                              "#{missing.join(", ")}; Oracle::Recorded::Journaling reads the full " \
                              "#{LIVE_TIER_DUCK.join(", ")} duck -- a replay tier (Oracle::Recorded) " \
                              "does not belong here, see the class doc"
      end
    end
  end
end
