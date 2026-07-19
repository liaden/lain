# frozen_string_literal: true

module Lain
  module Bench
    # OR-4, the decider-locus sweep: for T4's prune-scoring decision point
    # ("is this span stale?"), ranks the five loci oracles.md names -- heuristic,
    # ollama, haiku, inline, and model_self_directed (the DCP `compress`-tool
    # arm) -- over one committed fixture of decision-point cases.
    #
    # Unlike {Sweep} and {DisclosureSweep}, this sweep reuses {Compare} ITSELF,
    # not just {Compare::Distribution}/{Compare::Table}: T5 added exactly the
    # column (cache-write) this sweep exists to surface, and once each arm is
    # priced through its own {Ledger}-backed {Timeline}, {Compare::Run}'s
    # usage/cost/score shape is the right one -- {Sweep}'s own comment
    # documents why THAT sweep could not reuse it (no Ledger-priced Timeline);
    # here there is one, by construction.
    #
    # This class owns RANKING and RENDERING only. Building each arm's own
    # Timeline/Ledger/verdicts is {Arms}'s job; loading and validating the
    # committed YAML is {Fixture}'s -- both private collaborators, split out
    # (as separate FILES, see the require at the bottom) once the combined
    # responsibility outgrew a single class, per CLAUDE.md's "never loosen a
    # Metrics/* limit" rule.
    #
    # == One Oracle::Definition per arm, all five tiers of ONE oracle
    #
    # {Oracle::PruneScoring.definition(tier:)} takes any tier symbol, so
    # {Arms} does not special-case its two non-oracle-shaped arms: `inline`
    # and `model_self_directed` are simply two MORE tiers of the same oracle,
    # answering the same schema, each at its own content-addressed digest.
    # `heuristic` runs the real {Oracle::PruneScoring.heuristic} predicate,
    # live and free; the other four are always replayed through
    # {Oracle::Recorded}, fed manufactured {Telemetry::OracleAnswer} records
    # built from the fixture's committed `answer`/`usage`/`wall_clock` --
    # zero network by construction, whatever the tier's real-world cost shape.
    #
    # == Isolation: one Timeline, one Store, per arm
    #
    # Every arm scores over its OWN {Timeline} on its OWN {Store} -- built
    # fresh in {Arms}, never the actual object a live run would hold, so
    # nothing this sweep does can pollute a real conversation. `inline` and
    # `model_self_directed` are the two arms whose Timeline is NOT empty: it
    # is seeded with the fixture's `base_conversation` (standing in for "the
    # run under study"), because their entire reason for existing in this
    # sweep is to show what deciding INSIDE that conversation costs -- an
    # already-cached, >4096-token prefix, where a decision turn appended after
    # it genuinely triggers a cache write (Anthropic's floor, CLAUDE.md). The
    # other three arms are one-shot, out-of-band calls whose tiny prompts never
    # reach that floor, so their cache-write column is honestly zero -- not
    # smoothed, not averaged, just what a short prompt costs. See {#timelines}.
    #
    # == Wall-clock: replayed history, never fabricated
    #
    # `ollama` and `haiku`'s fixture entries carry a `wall_clock` VALUE --
    # a real number from the run that produced the recording, replayed as
    # history, not measured now. `heuristic`, `inline`, and
    # `model_self_directed` have never been live-timed by this sweep, so their
    # wall-clock cells read ABSENT rather than a fabricated constant -- see
    # {#wall_clock_section}. A live variant of this sweep would time those
    # arms for real and stop being byte-identical across repeats by
    # construction; this default posture is the byte-identical, zero-network
    # one.
    class DeciderSweep
      # A missing fixture path -- a checkout or packaging mistake, never user
      # input to refuse. Named and path-bearing like {Sweep::MissingCorpus}.
      class MissingFixture < Lain::Error; end

      # A fixture case missing a required field -- a malformed fixture is a
      # bug in the fixture to surface loudly, never a case to silently skip.
      class MalformedCase < Lain::Error; end

      # Declared order also becomes the tie-break order in {#ranked_runs}: an
      # ordinary Array, never a Hash whose iteration a future insertion could
      # silently reorder.
      ARMS = %w[heuristic ollama haiku inline model_self_directed].freeze

      # ollama runs a local model for free (oracles.md's cost table); the
      # PriceBook's own DEFAULTS name only the three Anthropic families, so an
      # unmatched model would otherwise raise {PriceBook::UnknownModel} for
      # the one arm that is genuinely, honestly $0.
      ZERO_PRICE = Price.per_mtok(input: 0, output: 0, cache_creation: 0, cache_read: 0)
      private_constant :ZERO_PRICE

      WALL_CLOCK_COLUMNS = %w[arm n mean median min max].freeze
      private_constant :WALL_CLOCK_COLUMNS

      # Short on purpose -- see the wall-clock section's own header line for
      # the full explanation; a table column is not the place for prose.
      ABSENT = "ABSENT (dry)"
      private_constant :ABSENT

      # @param fixture_path [String] a committed YAML fixture of decision-point
      #   cases (see spec/fixtures/bench/decider/*.yml for the shape)
      # @param price_book [Lain::PriceBook] defaults to a book that prices the
      #   three Anthropic families and falls back to $0 for anything else
      #   (the ollama arm)
      def initialize(fixture_path:, price_book: PriceBook.new(fallback: ZERO_PRICE))
        @fixture = Fixture.new(fixture_path)
        @arms = Arms.new(fixture: @fixture, price_book:)
      end

      # A Compare report over grader score, tokens, cost, and cache-write,
      # followed by a wall-clock section Compare itself has no column for.
      # Returned as a String -- never printed (output discipline). Memoized
      # so "report twice" is byte-identical for free, the same guarantee
      # {Sweep#report} and {DisclosureSweep#report} give.
      #
      # @return [String]
      def report
        @report ||= render
      end

      # arm name => its own isolated {Timeline}, built on its own {Store} --
      # exposed so the isolation invariant the DCP review's escalation
      # trigger names is directly checkable, not just implied by the report's
      # numbers.
      #
      # @return [Hash{String=>Lain::Timeline}]
      def timelines = @arms.timelines

      private

      def render
        [header, "", Compare.new(ranked_runs).report, "", wall_clock_section].join("\n")
      end

      def header
        "Decider sweep — #{@fixture.cases.size} cases, #{ARMS.size} arms (#{ARMS.join(" vs ")})"
      end

      # Sorted by grader score descending (ties broken by name, never Hash
      # order) -- the "ranks decider arms" the class exists to do; {Compare}
      # itself does not sort, so the ranking is this sweep's own.
      def ranked_runs
        ARMS.map { |arm| @arms.run_for(arm) }.sort_by { |run| [-run.score.to_f, run.name] }
      end

      def wall_clock_section
        rows = ARMS.map { |arm| wall_clock_row(arm) }
        ["== Wall clock (live/LiveReplay arms only; replayed history, never fabricated) ==", "",
         Compare::Table.new(headers: WALL_CLOCK_COLUMNS, rows:).to_s].join("\n")
      end

      def wall_clock_row(arm)
        samples = @arms.wall_clock_samples(arm)
        return [arm, "0", ABSENT, ABSENT, ABSENT, ABSENT] if samples.empty?

        dist = Compare::Distribution.new(samples)
        [arm, dist.n.to_s, *[dist.mean, dist.median, dist.min, dist.max].map { |value| format("%.3f", value) }]
      end
    end
  end
end

# After the class body, the same children-after-the-class-body load order
# compare.rb's own Table follows: {Fixture} and {Arms} reopen DeciderSweep
# (and Fixture raises DeciderSweep's own MissingFixture/MalformedCase, both
# already defined above), and nothing in the body above needs either before
# runtime. Split into their own FILES, not nested classes in this one,
# because Metrics/ClassLength counts a nested class's lines as the enclosing
# class's own -- moving the file is what actually extracts the collaborator
# (CLAUDE.md: never loosen the limit).
require_relative "decider_sweep/fixture"
require_relative "decider_sweep/arms"
