# frozen_string_literal: true

module Lain
  module CLI
    # Turns `--compact-strategy <name>` into the {Compaction::Strategy::Base}
    # a compacting derivation collapses spans with: which policy, and -- when
    # the policy is model-backed -- which recorded oracle it answers through.
    # {IsolationBackend} (cli/isolation_backend.rb:78) is this class's exact
    # precedent: {STRATEGIES} is the single authority both the resolution and
    # the flag's help text read, and an unknown name is refused loudly, naming
    # the flag and the valid set. What it does NOT share with that precedent is
    # {DEFAULT}, which is a fallback for a nil ARGUMENT and emphatically not
    # for an unset FLAG -- read the constant's own doc before using it.
    #
    # A STANDALONE class, not a {Backend} method: {Backend} sits at 108 of 110
    # on `Metrics/ClassLength` (CLAUDE.md's "extract, never loosen"), so a
    # resolver method there would cross the cop.
    #
    # == A NAME MAY BE A COMPOSITION, SPELLED WITH `+`
    #
    # `elide-tools+summarize-conversation` resolves each part and folds them
    # with {Compaction::Strategy::Base#|}, which builds {Compaction::Strategy::
    # Composed}. That operation is a declared COMMUTATIVE MONOID
    # (`strategy/base.rb:235`), so the order the parts are written in is not a
    # semantic, and a one-part name folds to the leaf itself rather than to a
    # composition of one.
    #
    # `+` and not `|` or `,`: `|` is a pipe to every shell an operator would
    # type this into, and `,` reads as "a list of alternatives" where this is a
    # single strategy made of two. Thor treats `+` as an ordinary value
    # character in both `--flag value` and `--flag=value` forms (probed), so
    # nothing here is escaped -- and the day a separator DOES collide, change
    # this constant rather than teaching the flag to escape.
    #
    # THE COMPOSITION IS ONLY AS DISJOINT AS ITS PARTS. {Composed} raises
    # `Overlap` from `#propose_ranges`, which needs the messages and the span,
    # and this resolver has neither -- so `elide+summarizing`, two whole-span
    # strategies, CONSTRUCTS here and refuses at the first compacting turn. The
    # pair that is disjoint by construction is `elide-tools` and
    # `summarize-conversation`: both route their selection through
    # {Compaction::ToolMessages}, so they are exact complements rather than two
    # spellings that happen to agree, and that pair is the recommended
    # composition. Refusing a whole-span pair HERE would need a static "claims
    # the whole span" declaration on {Compaction::Strategy::Base}, which is a
    # design decision for its own card and not a tidy-up.
    #
    # ONE `tier:` CALL PER RESOLUTION, however many oracle-backed parts the
    # name has. {Compaction::Strategy::SummarizeConversation}'s own doc states
    # the invariant -- "Two strategies, one oracle, one journal" -- and it is
    # what keeps a resumed session reconciling one recorded address per span
    # question instead of one per leaf.
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
      # text lists them: the two whole-span policies first -- model-backed
      # ahead of deterministic -- then the two narrowed ones in the same order,
      # since those are the pair a reader is meant to see as complements.
      #
      # A name may also be several of these joined by {SEPARATOR}, which is not
      # listed here: this is the set of LEAVES, and the compositions over it
      # are not enumerable.
      STRATEGIES = %w[summarizing elide summarize-conversation elide-tools].freeze

      # What joins two strategy names into one composition. See the class doc
      # for why `+` rather than `|` or `,`, and for what a composition means.
      SEPARATOR = "+"

      # What a nil NAME means to this resolver, and nothing beyond that.
      #
      # IT IS NOT WHAT AN UNSET `--compact-strategy` MEANS. An unset flag means
      # the run's own EAGER tool-result tier -- the control arm every flagged
      # run is measured against -- and {Backend::SpanSummarizer#strategy}
      # (`backend/span_summarizer.rb:19-48, 76-80`) short-circuits on nil and
      # never reaches this class at all, which is the only reason the two have
      # not yet been confused in a shipped run. They differ in what the chat
      # actually pays: the eager tier's summaries were already fired off the
      # critical path per tool result, while `summarizing` is a fresh model
      # call per span AT compaction time.
      #
      # So a future caller writing
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
      #   that MUST build its tier over the exact `definition` it is handed
      #   -- never a pre-built tier, never a tier built against a definition
      #   of the factory's own. Called at most once PER RESOLUTION -- once for
      #   a whole composition, never once per oracle-backed part -- with
      #   {Compaction::Strategy::Summarizing}'s own {Oracle::Definition}, only
      #   when the resolved name has a model-backed part, and must answer the full
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
      # `String()` would COERCE rather than refuse, and both directions of that
      # are wrong here: `String(:elide)` answers `"elide"` and resolves
      # cleanly, which blesses a caller's type confusion in silence, while
      # `String([1])` answers `"[1]"` and then refuses under a garbled name
      # that says nothing about the real mistake. This class refuses a wrong
      # shape before construction and names it -- {MissingTier} and
      # {IncompleteTier} are the same doctrine.
      #
      # NOT reachable from Thor, which parses a String or nothing. It IS
      # reachable from {Backend}, which reads `@options[:compact_strategy]` out
      # of a Hash a caller may have assembled by hand -- and `Symbol#empty?`
      # EXISTS, so a Symbol used to pass every guard below and die on
      # `Symbol#split` with an uncontained `NoMethodError`. {Unknown} is a
      # {Lain::Error} and `exe/lain:51` renders it as a clean one-liner; a
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
      # already known to be in {STRATEGIES} -- {Backend#provider_name}'s shape.
      #
      # Names the PART and the VALUE IT CAME FROM, always, and the two differ
      # exactly when the mistake is a separator one. `--compact-strategy
      # elide-tools+` refuses on the empty trailing part, and reporting that as
      # `unknown --compact-strategy ""` is loud and FALSE about what was typed
      # -- nobody passed an empty flag, and the next reader goes hunting a
      # shell-quoting bug. `++`, `+elide` and `elide++summarizing` all had the
      # same problem. For a plain single name the two halves coincide, which
      # costs a few redundant characters and keeps one message shape.
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
      #
      # MEMOIZED, so a composition naming two oracle-backed leaves calls
      # `tier:` once and both answer through ONE wrap -- which is what the
      # `tier:` doc promises ("called at most once") and what
      # {Compaction::Strategy::SummarizeConversation}'s doc means by "two
      # strategies, one oracle, one journal". Two wraps would put one span's
      # answer on the journal under two oracles and give a resume two
      # addresses to reconcile for one question. It never answers nil, so `||=`
      # cannot memoize a failure.
      #
      # @param part [String] the strategy name that wanted the tier. Named in
      #   the refusal, because there is now more than one oracle-backed name
      #   and a message hard-coding `summarizing` is wrong for three of the
      #   four things that can reach here (`summarize-conversation`, and either
      #   of them inside a composition). The same drift `STRATEGIES.inspect`
      #   in {#validated}'s message exists to prevent, one error class over.
      def recorded_oracle(part)
        raise MissingTier, "CompactionStrategy.resolve needs tier: to build #{part.inspect}" if @tier.nil?

        @recorded_oracle ||= journaling(Compaction::Strategy::Summarizing.definition)
      end

      def journaling(definition)
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
