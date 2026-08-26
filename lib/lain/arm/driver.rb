# frozen_string_literal: true

module Lain
  class Arm
    # Runs N arms over a task suite and folds each ARM's runs into its own
    # per-metric distributions -- grader score, tokens, wall-time, dollars --
    # laid side by side as a scannable report, under a header naming what
    # produced it.
    #
    # A Compare-STYLE report, not a {Compare}: Compare folds many runs across a
    # single axis into one distribution PER METRIC, whereas the Driver folds
    # each arm's runs into ITS OWN distributions and ranks the arms next to each
    # other. It reuses the two pieces that fit verbatim,
    # {Compare::Distribution} and {Compare::Table}, and renders its own
    # per-metric tables. Wall-time is a real distribution here because a
    # {Compare::Run} does not model it -- it rides on {Arm::Run} instead.
    class Driver
      # Each metric: how to pull one value off a {Run}, and how to render it.
      # One titled table per metric, rows = arms, so every column comes from one
      # declared source.
      #
      # `cost (USD)` is a DELIBERATE, SIZED DEBT against the roadmap item that
      # owns collapsing the four metric registries in `lib/` (two incompatible
      # shapes: this `{of:, fmt:}` and {Compare::METRICS}' `{label:, reader:,
      # fmt:}`). It is one entry in the pre-collapse shape rather than the
      # computed-total metric a `token-cost + $/sec x wall-clock` axis would
      # need, which neither shape can express and which that item would then
      # have to undo.
      METRICS = {
        "grader score" => { of: :score, fmt: ->(value) { format("%.3f", value) } },
        "total tokens" => { of: :total_tokens, fmt: ->(value) { format("%.1f", value) } },
        "wall-time (s)" => { of: :elapsed, fmt: ->(value) { format("%.4f", value) } },
        "cost (USD)" => { of: :cost, fmt: ->(value) { format("%.6f", value) } }
      }.freeze
      private_constant :METRICS

      COLUMNS = %w[arm n mean median min max].freeze
      private_constant :COLUMNS

      # What an attribution field prints when the caller supplied none. A BLANK
      # field reads as "there was none"; this says the record does not know,
      # which is the weaker claim and the true one.
      UNRECORDED = "unrecorded"
      private_constant :UNRECORDED

      # A metric the arm's own {PriceBook} could not answer, standing where a
      # {Compare::Distribution} would. It carries the LEDGER's message rather
      # than a number, so the section that renders it says both that there is no
      # figure and what would produce one -- see {#fold}.
      Unpriced = Data.define(:reason)
      private_constant :Unpriced

      # @param arms [Array<Arm>] the topologies under comparison
      # @param tasks [Array<String>] the suite; n >= 2 so each arm's fold is a
      #   real distribution rather than a single-sample point
      # @param spawn_seam [#call] the agent/child factory threaded into every arm
      # @param grader [#grade] scores each run's Timeline
      # @param isolation [#acquire] the injected backend, threaded into every arm
      # @param fixture [String, nil] where the suite came from, for the header;
      #   the Driver is handed prompts, so nothing else here can name it
      # @param model [String, nil] what the arms were configured to ask, for the
      #   header. What was ASKED FOR, which is not necessarily what each payment
      #   RECORDED -- the cost column prices the latter, per payment.
      # @param isolation_name [String, nil] the operator's own word for the
      #   backend (the `--isolation` value), used as the header's label. Every
      #   name `bench arms` can resolve comes back wrapped in the SAME
      #   {Isolation::Journal} decorator, so a class name cannot tell `none` from
      #   `worktree`; this can.
      # @raise [ArgumentError] on fewer than two tasks or no arms
      def initialize(arms, tasks:, spawn_seam:, grader:, isolation: NoIsolation, isolation_name: nil,
                     fixture: nil, model: nil)
        @arms = Array(arms).freeze
        @tasks = Array(tasks).freeze
        raise ArgumentError, "the driver needs at least one arm to compare" if @arms.empty?
        raise ArgumentError, "a distribution needs n >= 2 tasks; one run is not a distribution" if @tasks.size < 2

        @spawn_seam = spawn_seam
        @grader = grader
        @isolation = isolation
        @isolation_name = isolation_name
        @fixture = fixture
        @model = model
      end

      # A scannable report as a String -- never printed (output discipline). One
      # titled table per metric, each row an arm's distribution over the suite.
      #
      # @return [String]
      def report
        @report ||= render(measured)
      end

      private

      # [arm_name, {metric_label => Distribution}] per arm, in the order given.
      def measured
        @arms.map { |arm| [arm.name, distributions_for(arm)] }
      end

      def distributions_for(arm)
        runs = @tasks.map { |task| arm.run(task, spawn_seam: @spawn_seam, isolation: @isolation, grader: @grader) }
        METRICS.transform_values { |spec| fold(runs, spec) }
      end

      # One metric across one arm's runs -- or, where the arm's own PriceBook
      # cannot answer, a named refusal instead of a Distribution.
      #
      # THE RESCUE IS THE WHOLE DEGRADATION, and it belongs here rather than one
      # frame out. `Ledger#cost_of` raises {PriceBook::UnknownModel} for a model
      # the book has no row for, and `lain bench arms FIXTURE --provider ollama`
      # reaches that with NO further flags (`qwen3:4b` against a DEFAULTS of
      # opus/sonnet/haiku). Letting it out of here took the WHOLE report down --
      # score, tokens and wall-time included, none of which ever needed a model
      # -- and did it AFTER every run was already paid for, with `@report ||=`
      # never memoising on the raise path, so a retry re-ran and re-paid the
      # suite for no record.
      #
      # Rescuing to ZERO would be the worse error: that is the lie {PriceBook}
      # and {Ledger#initialize} each refuse in writing. But refusing to name a
      # PRICE is not the same as destroying the REPORT, so the cost SECTION
      # degrades to the Ledger's own message and every other section renders.
      def fold(runs, spec)
        Compare::Distribution.new(runs.map { |run| run.public_send(spec.fetch(:of)) })
      rescue PriceBook::UnknownModel => e
        Unpriced.new(reason: e.message)
      end

      def render(measured_arms)
        [header, *METRICS.keys.map { |label| section(label, measured_arms) }].join("\n\n")
      end

      # An unattributable bench report is a weak experiment record, and a DOLLAR
      # figure on a report naming no model is the lie {PriceBook} refuses to
      # tell. Attribution ONLY: no credential and no provider base URL reaches
      # here, and none may -- a report is pasted into an issue, and
      # `spec/output_discipline_spec.rb` cannot see inside a String.
      def header
        ["Arm driver — #{@arms.size} arms over #{@tasks.size} tasks",
         "  fixture:   #{attributed(@fixture)}",
         "  model:     #{attributed(@model)}",
         "  isolation: #{isolation_label}"].join("\n")
      end

      # BLANK IS UNSET, not an attribution -- {Bench::SpawnSeam}'s own rule for
      # `--system`, applied for the same reason: `--model ''` is truthy, and a
      # truthiness guard would render an empty field, which reads as "there was
      # none" rather than "the record does not know".
      def attributed(value) = Blankness.blank?(value) ? UNRECORDED : value

      # THE OPERATOR'S OWN WORD FIRST, and a class name only where there is no
      # word to use. {Bench::CLI#lease_options} requires a journal whenever
      # `--isolation` is set, so the concrete backend always comes back wrapped
      # in {Isolation::Journal} -- which renders `none` and `worktree`
      # IDENTICALLY and cannot answer the one question this field exists for. It
      # would also disagree with the lease records under the same report, since
      # {Isolation::Journal} emits `backend:` for the backend it WRAPS.
      #
      # {NoIsolation} wins over any name, because it is the object that actually
      # leased: a bare module holding nothing. That a run leased nothing is a
      # fact about the experiment, not a blank field.
      def isolation_label
        return "unset — Arm::NoIsolation leased nothing" if @isolation.equal?(NoIsolation)

        Blankness.blank?(@isolation_name) ? attributed(@isolation.class.name) : @isolation_name
      end

      # ONE REFUSED ARM REFUSES THE SECTION, not just its row. A table carrying
      # figures for the arms that priced and a gap for the one that did not
      # invites exactly the comparison the missing number cannot support, which
      # is the reading a bench report exists to prevent.
      def section(label, measured_arms)
        folds = measured_arms.map { |(name, dists)| [name, dists.fetch(label)] }
        unpriced = folds.map(&:last).grep(Unpriced)

        unpriced.any? ? refused(label, unpriced) : table(label, folds)
      end

      def table(label, folds)
        fmt = METRICS.fetch(label).fetch(:fmt)
        rows = folds.map do |(name, dist)|
          [name, dist.n.to_s, *[dist.mean, dist.median, dist.min, dist.max].map(&fmt)]
        end
        "#{label}\n#{Compare::Table.new(headers: COLUMNS, rows:)}"
      end

      # The Ledger's OWN message, verbatim, because it already names the fix and
      # a second wording here would be a second authority on how to make a run
      # priceable. No arm is named, per {#section}.
      def refused(label, unpriced)
        "#{label}\n  not priced — #{unpriced.map(&:reason).uniq.join("; ")}"
      end
    end
  end
end
