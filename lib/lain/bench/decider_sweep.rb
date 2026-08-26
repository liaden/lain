# frozen_string_literal: true

module Lain
  module Bench
    # The decider-locus sweep: for the prune-scoring decision point
    # ("is this span stale?"), ranks the five loci oracles.md names -- heuristic,
    # ollama, haiku, inline, and model_self_directed (the DCP `compress`-tool
    # arm) -- over one committed fixture of decision-point cases.
    #
    # Unlike {Sweep} and {DisclosureSweep}, this one reuses {Compare} ITSELF
    # rather than just its Table and Distribution: {Compare} carries exactly the
    # cache-write column this sweep exists to surface, and once each arm is
    # priced through its own {Ledger}-backed {Timeline}, {Compare::Run}'s
    # usage/cost/score shape is the right one. ({Sweep} could not reuse it, for
    # want of a Ledger-priced Timeline; here there is one by construction.)
    #
    # This class owns RANKING and RENDERING only. Building each arm's own
    # Timeline/Ledger/verdicts is {Arms}'s job and loading the committed YAML is
    # {Fixture}'s, both in separate FILES rather than nested classes, because
    # `Metrics/ClassLength` counts a nested class's lines as the enclosing
    # class's own.
    #
    # == One Oracle::Definition per arm, all five tiers of ONE oracle
    #
    # `Oracle::PruneScoring.definition(tier:)` takes any tier symbol, so {Arms}
    # does not special-case its two non-oracle-shaped arms: `inline` and
    # `model_self_directed` are two MORE tiers of the same oracle, answering the
    # same schema, each at its own content-addressed digest. `heuristic` runs
    # the real predicate, live and free; the other four are always replayed
    # through {Oracle::Recorded}, fed manufactured {Telemetry::OracleAnswer}
    # records built from the fixture's committed `answer`/`usage`/`wall_clock`
    # -- zero network by construction.
    #
    # == Isolation: one Timeline, one Store, per arm
    #
    # Every arm scores over its OWN {Timeline} on its OWN {Store}, built fresh
    # in {Arms} and never the object a live run would hold, so nothing this
    # sweep does can pollute a real conversation. `inline` and
    # `model_self_directed` are the two arms whose Timeline is NOT empty: it is
    # seeded with the fixture's `base_conversation`, because their whole reason
    # for existing here is to show what deciding INSIDE that conversation costs
    # -- an already-cached, >4096-token prefix, where a decision turn appended
    # after it genuinely triggers a cache write. The other three are one-shot,
    # out-of-band calls whose tiny prompts never reach that floor, so their
    # cache-write column is honestly zero: not smoothed, not averaged, just what
    # a short prompt costs.
    #
    # == Wall-clock: replayed history, never fabricated
    #
    # `ollama` and `haiku`'s fixture entries carry a `wall_clock` VALUE -- a
    # real number from the run that produced the recording, replayed as history,
    # not measured now. `heuristic`, `inline` and `model_self_directed` have
    # never been live-timed by this sweep, so their cells read ABSENT rather
    # than a fabricated constant. A live variant would time those arms for real
    # and stop being byte-identical across repeats by construction; this default
    # posture is the byte-identical, zero-network one.
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

      # ollama runs a local model for free; the PriceBook's own DEFAULTS name
      # only the three Anthropic families, so an unmatched model would otherwise
      # raise {PriceBook::UnknownModel} for the one arm that is honestly $0.
      ZERO_PRICE = Price.per_mtok(input: 0, output: 0, cache_creation: 0, cache_read: 0)
      private_constant :ZERO_PRICE

      WALL_CLOCK_FMT = ->(value) { format("%.3f", value) }
      private_constant :WALL_CLOCK_FMT

      # Short on purpose: the section's banner carries the explanation, and a
      # table column is not the place for prose.
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

      # A Compare report over grader score, tokens, cost and cache-write,
      # followed by a wall-clock section Compare has no column for. Memoized so
      # that reporting twice is byte-identical for free.
      #
      # @return [String]
      def report
        @report ||= render
      end

      # arm name => its own isolated {Timeline}, built on its own {Store}.
      # Exposed so the isolation invariant is directly checkable rather than
      # merely implied by the report's numbers.
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

      # Not an {Compare::ArmFold} SECTION: this table mixes measured rows with
      # absent ones and carries a prose banner instead of a bare title, so the
      # sweep assembles it and borrows the fold's row -- which is where the
      # column-to-cell pairing lives.
      def wall_clock_section
        rows = ARMS.map { |arm| wall_clock_row(arm) }
        ["== Wall clock (live/LiveReplay arms only; replayed history, never fabricated) ==", "",
         Compare::Table.new(headers: Compare::ArmFold::HEADERS, rows:).to_s].join("\n")
      end

      def wall_clock_row(arm)
        samples = @arms.wall_clock_samples(arm)
        return fold.absent_row(arm, count: 0, marker: ABSENT) if samples.empty?

        fold.row(arm, Compare::Distribution.new(samples), fmt: WALL_CLOCK_FMT)
      end

      def fold = @fold ||= Compare::ArmFold.new
    end
  end
end

# After the class body: {Fixture} and {Arms} reopen DeciderSweep and raise its
# own MissingFixture/MalformedCase, both defined above.
require_relative "decider_sweep/fixture"
require_relative "decider_sweep/arms"
