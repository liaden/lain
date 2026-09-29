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
      # `of:` is a Symbol {Arm::Run} answers directly for the first three rows.
      # `cost (USD)` reads the {Compare::Run}'s price, and `priced: true` marks
      # that its values are {Compare::Priced}/{Compare::Unpriced} rather than
      # numbers -- so the rescue of an unpriceable payment lives in Compare
      # alone, and this report refuses in Compare's words. `cache write tokens`
      # is a Proc reading `run.ledger.usage(run.timeline)` rather than
      # `run.compare_run.cache_write_tokens`: that would price the run just to
      # count its tokens. `optional: true` marks a metric {#fold} may answer as
      # {Unmeasured} rather than a {Measured} distribution -- see that method.
      METRICS = {
        "grader score" => { of: :score, fmt: ->(value) { format("%.3f", value) } },
        "total tokens" => { of: :total_tokens, fmt: ->(value) { format("%.1f", value) } },
        "wall-time (s)" => { of: :elapsed, fmt: ->(value) { format("%.4f", value) } },
        "cost (USD)" => { of: ->(run) { run.compare_run.price }, fmt: ->(value) { format("%.6f", value) },
                          priced: true },
        "cache write tokens" => {
          of: ->(run) { run.ledger.usage(run.timeline).cache_creation_input_tokens },
          fmt: ->(value) { format("%.1f", value) }, optional: true
        }
      }.freeze
      private_constant :METRICS

      COLUMNS = %w[arm n mean median min max].freeze
      private_constant :COLUMNS

      # How a graded subject is addressed for its {Telemetry::GradeRecord}.
      # Every arm hands its grader a {Timeline}, which carries no `#digest` of
      # its own -- its content address is its head turn's -- so the Driver
      # injects the resolution rather than leaving
      # {Grader::Journaling#digest_for} to its duck-typed fallbacks, which would
      # raise on a subject that is neither addressable nor a bare String.
      SUBJECT_DIGEST = :head_digest.to_proc.freeze
      private_constant :SUBJECT_DIGEST

      # What an attribution field prints when the caller supplied none. A BLANK
      # field reads as "there was none"; this says the record does not know,
      # which is the weaker claim and the true one.
      UNRECORDED = "unrecorded"
      private_constant :UNRECORDED

      # The one arm-cell shape {#fold} answers with when a real
      # {Compare::Distribution} was built. Wraps it (rather than handing the
      # Distribution straight to {#table}) so every shape {#fold} can answer
      # -- this, {Compare::Unpriced}, {Unmeasured} -- speaks the SAME
      # `#refuses?` protocol and {#section} sends one message instead of
      # testing which of the three it was handed.
      Measured = Data.define(:distribution) do
        def refuses? = false

        def row(name, fmt)
          [name, distribution.n.to_s,
           *[distribution.mean, distribution.median, distribution.min, distribution.max].map(&fmt)]
        end
      end
      private_constant :Measured

      # ONE arm's cell for an OPTIONAL metric whose own values could not be
      # told apart from "never measured" -- see {#fold}. {Usage} normalizes an
      # absent field (cache fields, on a provider or a scripted response that
      # never populates them) to 0, so 0 is what BOTH "measured, and it was
      # zero" and "never measured at all" look like once it is a {Usage}. This
      # is decided PER ARM, and does NOT refuse the section the way
      # {Compare::Unpriced} does: a sibling arm's real, measured distribution
      # under the SAME metric must still render, so hiding it behind this arm's
      # honest zero would be the false claim, not the fix.
      Unmeasured = Data.define(:n) do
        def refuses? = false
        def row(name, _fmt) = [name, n.to_s, *([NOT_MEASURED_CELL] * 4)]
      end
      private_constant :Unmeasured

      CeilingFailure = Data.define(:index)
      private_constant :CeilingFailure

      CEILING_REASON = "ceiling"
      private_constant :CEILING_REASON

      NOT_MEASURED_CELL = "not measured"
      private_constant :NOT_MEASURED_CELL

      # A task an arm never finished because it hit a ceiling. A run that
      # stopped there has no graded trajectory to fold, and a missing figure
      # averaged in as zero would read as a cheap success; the cell says so
      # instead, and only that arm's cell does.
      Failed = Data.define(:total, :indexes) do
        def refuses? = false

        def row(name, _fmt)
          label = "#{indexes.size == 1 ? "task" : "tasks"} #{indexes.join(", ")}"
          [name, "#{indexes.size} of #{total}", *(["failed: #{CEILING_REASON} (#{label})"] * 4)]
        end
      end
      private_constant :Failed

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
      # @param journal [#<<] where each graded run's {Telemetry::GradeRecord}
      #   lands. THE GRADE IS THE BENCH'S HEADLINE METRIC and, alone among the
      #   columns folded here, reached the rendered report and nothing else --
      #   usage and payments already ride the arms' own journal records. The
      #   Null channel by default, so no caller guards `if journal` -- and an
      #   explicit nil is REFUSED rather than treated as unset, because unlike
      #   its three sibling optional keywords a nil here survives construction
      #   and dies inside the decorator, after every arm has already been paid
      #   for. {Channel::Null::INSTANCE} is how a caller says "nowhere".
      # @raise [ArgumentError] on fewer than two tasks, no arms, or a nil journal
      def initialize(arms, tasks:, spawn_seam:, grader:, isolation: NoIsolation, isolation_name: nil,
                     fixture: nil, model: nil, journal: Channel::Null::INSTANCE)
        @arms = Array(arms).freeze
        @tasks = Array(tasks).freeze
        raise ArgumentError, "the driver needs at least one arm to compare" if @arms.empty?
        raise ArgumentError, "a distribution needs n >= 2 tasks; one run is not a distribution" if @tasks.size < 2
        raise ArgumentError, "journal: nil has nowhere to record a grade; pass Channel::Null::INSTANCE" if journal.nil?

        @spawn_seam = spawn_seam
        # DECORATED ONCE, HERE, because the grader is threaded verbatim into
        # every arm's `#run` -- so one wrap attests every arm's every run. An
        # arm that never consults the grader it was handed journals nothing,
        # truthfully: no arm this Driver can be given today behaves that way,
        # so it is a forward contract for the arms a project will author, not a
        # description of one in the tree.
        @journal = journal
        @grader = Grader::Journaling.new(inner: grader, journal:, subject_digest: SUBJECT_DIGEST)
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
        runs = @tasks.each_with_index.map { |task, index| run_task(arm, task, index + 1) }
        METRICS.transform_values { |spec| fold(runs, spec) }
      end

      def run_task(arm, task, number)
        arm.run(task, spawn_seam: @spawn_seam, isolation: @isolation, grader: @grader)
      rescue Agent::Budget::Exceeded => e
        journal_failure(task, number, e)
        CeilingFailure.new(index: number)
      end

      # The arm never handed back a Timeline, so the task's own prompt is the
      # only thing left to address the failed grade by.
      def journal_failure(task, number, error)
        @journal << Telemetry::GradeRecord.new(grader: self.class.name, score: 0.0, pass: false,
                                               why: "task #{number} failed at the ceiling: #{error.message}",
                                               subject_digest: Canonical.digest(task))
      end

      # One metric across one arm's runs -- or, where the arm's own PriceBook
      # cannot answer, a named refusal instead of a Distribution.
      #
      # The refusal must never escape as a raise. `lain bench arms FIXTURE
      # --provider ollama` reaches an unpriceable model with NO further flags
      # (`qwen3:4b` against a DEFAULTS of opus/sonnet/haiku), and a raise here
      # takes the WHOLE report down -- score, tokens and wall-time included --
      # AFTER every run is already paid for, with `@report ||=` never memoising
      # on the raise path, so a retry re-runs and re-pays the suite for no record.
      #
      # Folding a ZERO would be the worse error: that is the lie {PriceBook} and
      # {Ledger#initialize} each refuse in writing. So an arm whose price
      # {Compare::Run} could not name answers with that {Compare::Unpriced}.
      def fold(runs, spec)
        failed = runs.grep(CeilingFailure)
        return Failed.new(total: runs.size, indexes: failed.map(&:index)) if failed.any?

        values = runs.map { |run| value_of(run, spec.fetch(:of)) }
        return Unmeasured.new(n: values.size) if spec.fetch(:optional, false) && values.all?(&:zero?)
        return priced_fold(values) if spec.fetch(:priced, false)

        distributed(values)
      end

      def priced_fold(prices) = prices.find(&:refuses?) || distributed(prices.map(&:amount))

      def distributed(values) = Measured.new(distribution: Compare::Distribution.new(values))

      # `of:` is a Symbol for every metric {Arm::Run} answers directly, and a
      # Proc for one that needs a call {Run} does not expose on its own -- see
      # METRICS' comment on `cache write tokens`.
      def value_of(run, of) = of.respond_to?(:call) ? of.call(run) : run.public_send(of)

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

      # ONE {Compare::Unpriced} ARM REFUSES THE WHOLE SECTION -- every value
      # here answers `#refuses?` itself, so this sends one message rather than
      # testing which of {Measured}/{Compare::Unpriced}/{Unmeasured} it was
      # handed. An unpriceable model makes every arm's dollar figure equally
      # unknowable, so there is no single arm's row left to render. An
      # {Unmeasured} arm never refuses the section: it renders its OWN row,
      # per {#table}, because a sibling arm's real, measured distribution
      # under the same metric must not be hidden behind this arm's honest
      # zero -- exactly the comparison a table carrying a gap for the priced
      # arms and a figure for the one that could not price would also invite,
      # which is why {Compare::Unpriced} still refuses everything.
      def section(label, measured_arms)
        folds = measured_arms.map { |(name, dists)| [name, dists.fetch(label)] }
        refusing = folds.map(&:last).select(&:refuses?)

        refusing.any? ? refused(label, refusing) : table(label, folds)
      end

      def table(label, folds)
        fmt = METRICS.fetch(label).fetch(:fmt)
        rows = folds.map { |(name, cell)| cell.row(name, fmt) }
        "#{label}\n#{Compare::Table.new(headers: COLUMNS, rows:)}"
      end

      # Compare's wording, so the arm report and every Compare-backed report
      # refuse an unpriced cost in one voice. No arm is named, per {#section}.
      def refused(label, refusing)
        "#{label}\n  #{Compare::Unpriced.describe(refusing)}"
      end
    end
  end
end
