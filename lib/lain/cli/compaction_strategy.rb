# frozen_string_literal: true

module Lain
  module CLI
    # Turns `--compact-strategy <name>` into the {Compaction::Strategy::Base}
    # subclass a compacting derivation collapses spans with: which policy, and
    # -- when the policy is model-backed -- which recorded oracle it answers
    # through. {IsolationBackend} (cli/isolation_backend.rb:78) is this class's
    # exact precedent: {STRATEGIES} is the single authority both the
    # resolution and the flag's help text read, {DEFAULT} is what an unset
    # flag falls through to, and an unknown name is refused loudly, naming the
    # flag and the valid set.
    #
    # A STANDALONE class, not a {Backend} method: {Backend} sits at 108 of 110
    # on `Metrics/ClassLength` (CLAUDE.md's "extract, never loosen"), so a
    # resolver method there would cross the cop.
    #
    # THE TIER IS INJECTED AS A FACTORY, NEVER A PRE-BUILT ONE, AND NEVER
    # FETCHED. Two separate reasons force the factory shape, not one:
    #
    # 1. {Backend#eager} is memoized run state and a second, differing
    #    {Backend#pipeline_source} call raises {Backend::Rebound}
    #    (cli/backend.rb:337-345) -- reaching into a Backend instance here for
    #    its live tier would either double-bind that memo or silently build a
    #    second, disconnected one. So the caller hands its OWN tier-building
    #    know-how in, never a Backend reference.
    # 2. {Oracle::Recorded::Journaling} must render its journalled question
    #    from the SAME {Oracle::Definition} the wrapped tier itself answers
    #    through -- its own doc says so in as many words
    #    (`oracle/recorded.rb:97-99`). {Compaction::Strategy::Summarizing}
    #    owns that definition (`.definition`), so a tier built BEFORE this
    #    class knows it would be a tier built against a definition nobody
    #    here can see, and the definition this class wraps it with would
    #    necessarily be a second, different one -- a false record: the model
    #    answers one question, the journal names another. Taking `tier:` as
    #    `->(definition) { ... }` and calling it only once the definition is
    #    in hand makes "one definition, two uses" structural rather than a
    #    precondition nobody checks (the exact hazard {Compaction::
    #    SummarySnapshot} warns a mis-keyed address is). {Backend::Summarizer
    #    #oracle} (`cli/backend/summarizer.rb:33-44`) is this same shape one
    #    level further out: it too builds `definition` first, then calls a
    #    private `tier(definition)` to get the thing it wraps.
    #
    #    STRUCTURAL identity stops at "one object, one expression" -- nothing
    #    here can ask the tier the factory hands back what definition it
    #    answers through ({Oracle::Model} exposes no `#definition`), so a
    #    factory that DISCARDS its argument and builds against something else
    #    entirely still produces the false record silently, just one level
    #    out. The rule the factory itself must follow is therefore a rule
    #    only the caller can keep: **build the tier over the definition you
    #    are handed, not over one of your own.** (Giving {Oracle::Model} a
    #    `#definition` reader so this could be verified here too, rather than
    #    merely documented, is a follow-up outside this file.)
    #
    # THIS RESOLVER BUILDS THE LIVE PATH ONLY. `tier:` must answer the full
    # {Oracle::Model} duck -- `#ask`, `#model`, `#usage` -- because
    # {Oracle::Recorded::Journaling} reads all three (`oracle/recorded.rb:135`);
    # handing it a REPLAY tier ({Oracle::Recorded}, which answers only `#ask`)
    # resolves cleanly and then dies on the render path with an uncontained
    # `NoMethodError` the first time a span is asked to collapse --
    # {Compaction::Strategy::Summarizing#asked} rescues {Lain::Error}, and
    # `NoMethodError` is not one. {#recorded_oracle} refuses that shape here,
    # at resolve, instead. A resume/replay seam belongs directly against
    # {Compaction::Strategy::Summarizing.definition}, is a DIFFERENT resolver
    # question than "which strategy does `--compact-strategy` name", and is
    # deliberately not this class's job to design.
    #
    # THE SUMMARIZING BRANCH'S RETURN MUST NEVER BE REACHABLE FROM ANYTHING
    # HANDED TO `Ractor.make_shareable` ({Scheduler::COMPOSE},
    # {Source::BASE_PROVIDER}) -- {Compaction::Strategy::Summarizing}'s own
    # doc (`summarizing.rb:51-73`) is why: it holds a live oracle and a
    # mutable memo, so it is not, and cannot be made, `Ractor.shareable?`. The
    # two ways that goes wrong are NOT symmetric, which is worth knowing
    # rather than assumed: the LIVE tier this class builds fails more or less
    # BY ACCIDENT -- {Oracle::Recorded::Journaling}'s default `clock:` is a
    # Proc, and a Proc closing over unshareable `self` is what
    # `make_shareable` actually trips on, so it raises `Ractor::IsolationError`
    # -- while a Proc-free (e.g. resume/replay) graph has nothing for
    # `make_shareable` to object to and freezes SILENTLY, and the NEXT new
    # span then dies of an uncontained `FrozenError` on the render path,
    # which is not a {Lain::Error} either. {Compaction::Strategy::Elide}, on
    # the `elide` branch, is fully shareable end to end and needs no such
    # caveat.
    class CompactionStrategy
      # An unrecognized `--compact-strategy` name. Loud and naming the valid
      # set, {Backend#validated}'s voice: `--provider` and
      # `--compact-strategy` are different mistakes to make, so the message
      # says which flag was wrong.
      class Unknown < Error; end

      # {STRATEGIES} names a strategy that {#strategy}'s `case` has no branch
      # for -- an internal inconsistency in THIS class, never an operator's
      # flag typo, so it is deliberately not {Unknown}: raising {Unknown} here
      # would present a bug in the mapping as a mistake the `--compact-strategy`
      # caller made, the same confusion `--provider` vs `--compact-strategy`
      # naming {Unknown}'s own message apart exists to avoid.
      class Unbuilt < Error; end

      # The summarizing strategy was resolved with no `tier:` factory to
      # build its oracle from. Refused HERE, at resolution, rather than at
      # the first span a strategy is offered -- and addressed to the CALLER
      # of {.resolve}, since no CLI operator can supply a tier factory; only
      # code can.
      class MissingTier < Error; end

      # `tier:` built something that does not answer the full live-tier duck
      # ({Oracle::Model}'s: `#ask`, `#model`, `#usage`) -- most likely a
      # REPLAY tier ({Oracle::Recorded}, `#ask` alone) handed to a resolver
      # that only ever builds the live path. Refused HERE, naming what is
      # missing, rather than left to crash {Oracle::Recorded::Journaling}'s
      # `#ask` with an uncontained `NoMethodError` at the first span.
      class IncompleteTier < Error; end

      # The strategies `--compact-strategy` selects between, in the order help
      # text lists them: the model-backed policy first, since it is the
      # default.
      STRATEGIES = %w[summarizing elide].freeze

      # An unset flag arrives as nil, and this constant -- not a Thor default
      # -- is what it falls through to, so one authority answers "what does no
      # `--compact-strategy` mean?"
      DEFAULT = "summarizing"

      # @return [Compaction::Strategy::Base] the resolved strategy
      def self.resolve(...) = new(...).strategy

      # @param name [String, nil] the `--compact-strategy` value; nil means
      #   {DEFAULT}
      # @param tier [#call, nil] a FACTORY, `->(definition) { live tier }`,
      #   that MUST build its tier over the exact `definition` it is handed
      #   -- never a pre-built tier, never a tier built against a definition
      #   of the factory's own. Called at most once, with
      #   {Compaction::Strategy::Summarizing}'s own {Oracle::Definition}, only
      #   when the resolved strategy is not `elide`, and must answer the full
      #   live-tier duck (`#ask`, `#model`, `#usage` -- {Oracle::Model}'s);
      #   see the class doc for why a factory rather than a value, why the
      #   caller (not this class) is what keeps the one-definition rule, and
      #   why a replay tier does not belong here.
      # @param sink [Lain::Sink] where {Compaction::Strategy::Summarizing}
      #   reports a tier's failure (a down summarizer leaves a span
      #   uncollapsed rather than dying); the Null sink by default
      # @param journal [#<<] where the wrapped oracle's `oracle_answer`
      #   records land; the Null channel (the default) means nothing is
      #   journalled
      def initialize(name = nil, tier: nil, sink: Sink::Null.new, journal: Channel::Null.instance)
        @name = name || DEFAULT
        @tier = tier
        @sink = sink
        @journal = journal
      end

      # @return [Compaction::Strategy::Base] the resolved strategy
      # @raise [Unknown] on a name outside {STRATEGIES}
      # @raise [Unbuilt] a name in {STRATEGIES} with no matching branch below
      #   (a bug in this class, not a bad flag)
      # @raise [MissingTier] resolving `summarizing` with no `tier:` given
      # @raise [IncompleteTier] `tier:` built something that does not answer
      #   the full live-tier duck
      def strategy
        name = strategy_name
        case name
        when "summarizing" then Compaction::Strategy::Summarizing.new(oracle: recorded_oracle, sink: @sink)
        when "elide" then Compaction::Strategy::Elide.new
        else raise Unbuilt, "#{name.inspect} is in STRATEGIES but no branch here builds it"
        end
      end

      private

      # Validated once, so the mapping above only ever sees a name already
      # known to be in {STRATEGIES} -- {Backend#provider_name}'s shape.
      def strategy_name
        return @name if STRATEGIES.include?(@name)

        raise Unknown, "unknown --compact-strategy #{@name.inspect}, expected one of #{STRATEGIES.inspect}"
      end

      # What {Oracle::Recorded::Journaling#ask} reads off its `inner`
      # (`oracle/recorded.rb:135`): the full live-tier duck, {Oracle::Model}'s.
      # A REPLAY tier ({Oracle::Recorded}) answers `#ask` alone, which is
      # exactly the shape that used to resolve cleanly and then die on the
      # render path with an uncontained `NoMethodError` -- see {IncompleteTier}.
      LIVE_TIER_DUCK = %i[ask model usage].freeze
      private_constant :LIVE_TIER_DUCK

      # Builds the definition once, then the tier over it, then wraps that
      # tier in {Oracle::Recorded::Journaling} -- never a bare
      # {Oracle::Model} -- so its answers are journalled and a later resume
      # re-derives the same chain from {Oracle::Recorded.from_journal}
      # instead of re-asking a live model (the plan's "journal the edge,
      # re-derive" ruling).
      def recorded_oracle
        raise MissingTier, "CompactionStrategy.resolve needs tier: to build the summarizing strategy" if @tier.nil?

        definition = Compaction::Strategy::Summarizing.definition
        Oracle::Recorded::Journaling.new(inner: live_tier(definition), definition:, journal: @journal)
      end

      # Refuses HERE, naming what is missing, rather than handing
      # {Oracle::Recorded::Journaling} something it will crash on inside
      # `#ask` -- this codebase's own pattern ({MissingTier},
      # {Backend::InvalidCeiling}, {IsolationBackend::NotARepository}):
      # refuse before construction, not at the first use.
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
