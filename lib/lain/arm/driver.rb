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
      # that its values are {Compare::Cost::Priced}/{Compare::Cost::Unpriced} rather than
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

      STAT_FOLD = Compare::ArmFold.new
      private_constant :STAT_FOLD

      # How a graded subject is addressed for its {Telemetry::GradeRecord}.
      # Every arm hands its grader a {Ext::Timeline}, which carries no `#digest` of
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
      # -- this, {Compare::Cost::Unpriced}, {Unmeasured} -- speaks the SAME
      # `#refuses?` protocol and {#section} sends one message instead of
      # testing which of the three it was handed.
      Measured = Data.define(:distribution) do
        def refuses? = false
        def note(_name) = nil

        def row(name, fmt) = STAT_FOLD.row(name, distribution, fmt:)
      end
      private_constant :Measured

      # ONE arm's cell for an OPTIONAL metric whose own values could not be
      # told apart from "never measured" -- see {#fold}. {Usage} normalizes an
      # absent field (cache fields, on a provider or a scripted response that
      # never populates them) to 0, so 0 is what BOTH "measured, and it was
      # zero" and "never measured at all" look like once it is a {Usage}. This
      # is decided PER ARM, and does NOT refuse the section the way
      # {Compare::Cost::Unpriced} does: a sibling arm's real, measured distribution
      # under the SAME metric must still render, so hiding it behind this arm's
      # honest zero would be the false claim, not the fix.
      Unmeasured = Data.define(:n) do
        def refuses? = false
        def note(_name) = nil
        def row(name, _fmt) = STAT_FOLD.absent_row(name, count: n, marker: NOT_MEASURED_CELL)
      end
      private_constant :Unmeasured

      # The arm drains its own journal to price, so the stamped copy for the run journal is made here.
      SandboxCopy = Class.new(SimpleDelegator) do
        def initialize(journal, copy:)
          super(journal)
          @copy = copy
        end

        def <<(record)
          @copy << record if record.is_a?(Telemetry::Sandbox)
          __getobj__ << record
          self
        end
      end
      private_constant :SandboxCopy

      # Hands each spawn a {SandboxCopy} of the journal the arm gave it.
      CopyingSeam = Data.define(:seam, :copy) do
        # @param journal [#<<] the arm's own journal
        # @param options [Hash] passed to the seam unchanged
        # @option options [Object] :worker_env the lease's environment, among the seam's other keywords
        # @return [Lain::Agent]
        def call(journal:, **options) = seam.call(journal: SandboxCopy.new(journal, copy:), **options)
      end
      private_constant :CopyingSeam

      PAIRED_HEADERS = %w[arm metric pairs mean-diff ci95 wins losses ties].freeze
      private_constant :PAIRED_HEADERS

      # `attempt` is nil on a single-attempt run, where "task 2" already says everything.
      TaskFailure = Data.define(:index, :attempt, :reason) do
        def label = attempt.nil? ? index.to_s : "#{index} attempt #{attempt}"
      end
      private_constant :TaskFailure

      CEILING_REASON = "ceiling"
      private_constant :CEILING_REASON

      # Past this many rounds a task is slow enough to be worth counting apart from the rest.
      LATE_ROUNDS = 5
      private_constant :LATE_ROUNDS

      # A suite that is a cut of a larger one. Naming the cut is the point: a quick tier's ranking says nothing
      # about the full set until the gap between them has been measured.
      Subset = Data.define(:of, :gap) do
        def stated? = !of.nil?

        def line(task_count)
          measured = gap.nil? ? "not measured" : format("%.3f", gap)
          "  subset of #{of} (#{task_count} tasks); gap to the full set #{measured}"
        end
      end
      Subset::NONE = Subset.new(of: nil, gap: nil)

      # Kept apart from the per-metric folds because these read pass/fail and the attempt order of each task,
      # which a flat list of runs has already thrown away.
      Outcomes = Data.define(:attempts_by_arm, :attempts) do
        def sections = [pass_k, rounds_to_pass, cost_per_solved]

        private

        def tasks_of(name) = attempts_by_arm.fetch(name)

        def passed?(result) = !result.is_a?(TaskFailure) && result.grade.pass?

        def pass_k
          rows = attempts_by_arm.map do |name, tasks|
            held = tasks.count { |tries| tries.all? { |result| passed?(result) } }
            [name, tasks.size.to_s, attempts.to_s, format("%.2f", held.fdiv(tasks.size))]
          end
          "pass^k\n#{Compare::Table.new(headers: %w[arm tasks k pass^k], rows:)}"
        end

        def rounds_to_pass
          rounds = attempts_by_arm.transform_values { |tasks| tasks.filter_map { |tries| first_pass(tries) } }
          rows = rounds.map { |name, values| rounds_row(name, values, tasks_of(name).size) }
          notes = rounds.map { |name, values| late_note(name, values, tasks_of(name).size) }
          ["rounds to pass\n#{Compare::Table.new(headers: Compare::ArmFold::HEADERS, rows:)}",
           *notes.map { |note| "  #{note}" }].join("\n")
        end

        def first_pass(tries) = tries.index { |result| passed?(result) }&.succ

        def rounds_row(name, values, total)
          return STAT_FOLD.absent_row(name, count: "0 of #{total}", marker: "no task passed") if values.empty?

          STAT_FOLD.row(name, Compare::Distribution.new(values), fmt: ->(value) { format("%.1f", value) })
        end

        def late_note(name, values, total)
          late = values.count { |rounds| rounds >= LATE_ROUNDS }
          "#{name}: #{late} of #{total} tasks needed #{LATE_ROUNDS} or more rounds"
        end

        def cost_per_solved
          label = "cost per solved task (USD)"
          priced = attempts_by_arm.transform_values do |tasks|
            tasks.flatten.grep_v(TaskFailure).map do |run|
              run.compare_run.price
            end
          end
          unpriced = priced.values.flatten.select(&:refuses?)
          return "#{label}\n  #{Compare::Cost::Unpriced.describe(unpriced)}" if unpriced.any?

          rows = priced.map { |name, prices| cost_row(name, prices) }
          ["#{label}\n#{Compare::Table.new(headers: %w[arm spent passed cost], rows:)}", *excluded_notes].join("\n")
        end

        # A failed attempt was paid for but its spend died with the exception, so the cost above is a floor.
        def excluded_notes
          attempts_by_arm.filter_map do |name, tasks|
            lost = tasks.flatten.count { |result| result.is_a?(TaskFailure) }
            "  #{name}: spend excludes #{lost} failed #{lost == 1 ? "attempt" : "attempts"}" if lost.positive?
          end
        end

        def cost_row(name, prices)
          spent = prices.sum(BigDecimal(0), &:amount)
          passes = tasks_of(name).flatten.count { |result| passed?(result) }
          [name, format("%.6f", spent), passes.to_s, passes.zero? ? "no task solved" : format("%.6f", spent / passes)]
        end
      end
      private_constant :Outcomes

      NOT_MEASURED_CELL = "not measured"
      private_constant :NOT_MEASURED_CELL

      # A task an arm never finished because it hit a ceiling. A run that
      # stopped there has no graded trajectory to fold, and a missing figure
      # averaged in as zero would read as a cheap success; the cell says so
      # instead, and only that arm's cell does.
      Failed = Data.define(:total, :failures) do
        def refuses? = false
        def note(_name) = nil

        def row(name, _fmt)
          STAT_FOLD.absent_row(name, count: "#{failures.size} of #{total}", marker: "failed: #{reasons}")
        end

        private

        def reasons = FailureReasons.describe(failures)
      end
      private_constant :Failed

      # Wording for the failed tasks of an arm, shared by a wholly failed cell
      # and the note under a partial one.
      module FailureReasons
        def self.describe(failures)
          failures.group_by(&:reason).map do |reason, group|
            labels = group.map(&:label)
            "#{reason} (#{labels.size == 1 ? "task" : "tasks"} #{labels.join(", ")})"
          end.join("; ")
        end
      end
      private_constant :FailureReasons

      # An arm that lost some tasks and kept the rest: the figures are over the
      # survivors only, so `n` reads survivors of total and a note names what
      # was lost, rather than the arm passing as a complete one.
      Partial = Data.define(:cell, :total, :failures) do
        def refuses? = false

        def row(name, fmt)
          name, _n, *figures = cell.row(name, fmt)
          [name, "#{total - failures.size} of #{total}", *figures]
        end

        def note(name) = "#{name}: failed: #{FailureReasons.describe(failures)}"
      end
      private_constant :Partial

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
      # @param confine [String, nil] what the arms' shell was confined by, for the header; a run that
      #   confined nothing names no field, so its header stays what it was
      # @param journal [#<<] where each graded run's {Telemetry::GradeRecord}
      #   lands. THE GRADE IS THE BENCH'S HEADLINE METRIC and, alone among the
      #   columns folded here, reached the rendered report and nothing else --
      #   usage and payments already ride the arms' own journal records. The
      #   Null channel by default, so no caller guards `if journal` -- and an
      #   explicit nil is REFUSED rather than treated as unset, because unlike
      #   its three sibling optional keywords a nil here survives construction
      #   and dies inside the decorator, after every arm has already been paid
      #   for. {Channel::Null::INSTANCE} is how a caller says "nowhere".
      # @param attempts [Integer] fresh runs of each task per arm; above 1 the report adds pass^k, rounds to pass
      #   and cost per solved task
      # @param subset [Subset] what larger suite the tasks are a cut of, named in the header
      # @raise [ArgumentError] on fewer than two tasks, no arms, fewer than one attempt, or a nil journal
      def initialize(arms, tasks:, spawn_seam:, grader:, attempts: 1, subset: Subset::NONE, isolation: NoIsolation,
                     isolation_name: nil, fixture: nil, model: nil, confine: nil, journal: Channel::Null::INSTANCE)
        @arms = Array(arms).freeze
        @tasks = Array(tasks).freeze
        refuse_unrunnable!(attempts:, journal:, grader:)

        @attempts = attempts
        @subset = subset
        @spawn_seam = spawn_seam
        # DECORATED ONCE, HERE, because the grader is threaded verbatim into
        # every arm's `#run` -- so one wrap attests every arm's every run. An
        # arm that never consults the grader it was handed journals nothing,
        # truthfully: no arm this Driver can be given today behaves that way,
        # so it is a forward contract for the arms a project will author, not a
        # description of one in the tree.
        @journal = journal
        @grader = grader
        @isolation = isolation
        @isolation_name = isolation_name
        @fixture = fixture
        @model = model
        @confine = confine
      end

      # A scannable report as a String -- never printed (output discipline). One
      # titled table per metric, each row an arm's distribution over the suite.
      #
      # @return [String]
      def report
        @report ||= render(attempts_by_arm)
      end

      private

      def refuse_unrunnable!(attempts:, journal:, grader:)
        raise ArgumentError, "the driver needs at least one arm to compare" if @arms.empty?
        raise ArgumentError, "arm names must be unique; reports key by name" if @arms.map(&:name).uniq.size < @arms.size
        raise ArgumentError, "a distribution needs n >= 2 tasks; one run is not a distribution" if @tasks.size < 2
        raise ArgumentError, "attempts must be an Integer >= 1" unless attempts.is_a?(Integer) && attempts >= 1
        if attempts > 1 && !grader.respond_to?(:grade)
          raise ArgumentError,
                "attempts above 1 need a grader that answers grade"
        end
        raise ArgumentError, "journal: nil has nowhere to record a grade; pass Channel::Null::INSTANCE" if journal.nil?
      end

      def attempts_by_arm
        @arms.to_h do |arm|
          tries = @tasks.each_with_index.map do |task, index|
            Array.new(@attempts) { |attempt| run_task(arm, task, index + 1, attempt + 1) }
          end
          [arm.name, tries]
        end
      end

      # [arm_name, {metric_label => Distribution}] per arm, in the order given.
      def measured(runs_by_arm)
        runs_by_arm.map { |name, runs| [name, METRICS.transform_values { |spec| fold(runs, spec) }] }
      end

      def run_task(arm, task, number, attempt)
        copy = run_copy(arm, task)
        grader = Grader::Journaling.new(inner: @grader, journal: copy, subject_digest: SUBJECT_DIGEST)
        seam = CopyingSeam.new(@spawn_seam, copy)
        require_pass!(arm.run(task, spawn_seam: seam, isolation: @isolation, grader:))
      rescue Budget::Exceeded, Response::Failed => e
        failed(arm, task, [number, attempt], e)
      end

      def failed(arm, task, (number, attempt), error)
        reason = error.is_a?(Budget::Exceeded) ? CEILING_REASON : error.failure.stop_reason.to_s
        shown = @attempts > 1 ? attempt : nil
        where = reason == CEILING_REASON ? "at the ceiling" : reason
        journal_failure(arm, task, shown ? "#{number} attempt #{shown}" : number, where, error)
        TaskFailure.new(index: number, attempt: shown, reason:)
      end

      # The outcome tables read pass? off every grade, and learning a grade lacks it after the last arm was paid
      # for would waste the whole run.
      def require_pass!(run)
        return run if @attempts == 1 || run.grade.respond_to?(:pass?)

        raise ArgumentError, "attempts above 1 need a grade that answers pass?, got #{run.grade.class}"
      end

      def run_copy(arm, task) = Telemetry::Stamped::Sink.new(@journal, arm.name, Canonical.digest(task))

      # The arm never handed back a Timeline, so the task's own prompt is the
      # only thing left to address the failed grade by.
      def journal_failure(arm, task, number, where, error)
        run_copy(arm, task) << Telemetry::GradeRecord.new(
          grader: self.class.name, score: 0.0, pass: false,
          why: "task #{number} failed #{where}: #{error.message}", subject_digest: Canonical.digest(task)
        )
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
      # {Compare::Run} could not name answers with that {Compare::Cost::Unpriced}.
      def fold(runs, spec)
        failed = runs.grep(TaskFailure)
        survivors = runs - failed
        return Failed.new(total: runs.size, failures: failed) if survivors.empty? && failed.any?

        cell = fold_survivors(survivors, spec)
        failed.empty? || cell.refuses? ? cell : Partial.new(cell:, total: runs.size, failures: failed)
      end

      def fold_survivors(survivors, spec)
        values = survivors.map { |run| value_of(run, spec.fetch(:of)) }
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

      def render(attempts_by_arm)
        measured_arms = measured(attempts_by_arm.transform_values(&:flatten))
        [header, *METRICS.keys.map do |label|
          section(label, measured_arms)
        end, *paired_sections(attempts_by_arm.transform_values { |tries| tries.map(&:first) }),
         *outcome_sections(attempts_by_arm)].join("\n\n")
      end

      # Grade records exist for every attempt; the pairing uses each task's first, so a pair is still one task.
      def outcome_sections(attempts_by_arm)
        @attempts > 1 ? Outcomes.new(attempts_by_arm:, attempts: @attempts).sections : []
      end

      def paired_sections(runs_by_arm)
        (baseline, base_runs), *others = runs_by_arm.to_a
        return [] if others.empty?

        parts = others.map { |name, runs| rows_and_notes(baseline, name, base_runs.zip(runs)) }
        grid = Compare::Table.new(headers: PAIRED_HEADERS, rows: parts.flat_map(&:first))
        notes = ["wins = candidate higher", *parts.flat_map(&:last)]
        [["paired vs #{baseline}\n#{grid}", *notes.map { |note| "  #{note}" }].join("\n")]
      end

      def rows_and_notes(baseline, name, run_pairs)
        results = METRICS.reject { |_label, spec| spec.fetch(:optional, false) }
                         .transform_values { |spec| paired_of(baseline, name, run_pairs, spec) }
        refusals, measured = results.partition { |_label, result| result.is_a?(String) }
        [measured.map { |label, result| paired_row(name, label, result) },
         [*refusals.map { |label, why| "#{label}: #{why}" }, *unpaired_note(name, measured.map(&:last))]]
      end

      def paired_of(baseline, name, run_pairs, spec)
        sides = run_pairs.each_with_index.to_h { |pair, index| [index + 1, pair.map { |run| side(run, spec) }] }
        unpriced = sides.values.flatten.select { |side| side.respond_to?(:refuses?) && side.refuses? }
        return Compare::Cost::Unpriced.describe(unpriced) if unpriced.any?

        Compare::Paired.of(baseline:, candidate: name,
                           values_by_task: sides.transform_values { |pair| pair.map { |side| amount(side) } })
      end

      def side(run, spec) = run.is_a?(TaskFailure) ? run.reason : value_of(run, spec.fetch(:of))

      def amount(side) = side.respond_to?(:amount) ? side.amount : side

      def paired_row(name, label, result)
        return [name, label, "0", *Array.new(5, "-")] if result.pairs.empty?

        [name, label, result.pairs.size.to_s, format("%+.3f", result.mean_difference),
         interval_cell(result.interval, METRICS.fetch(label).fetch(:fmt)),
         result.wins.to_s, result.losses.to_s, result.ties.to_s]
      end

      def interval_cell(interval, fmt) = interval ? "#{fmt.call(interval.low)}..#{fmt.call(interval.high)}" : "-"

      def unpaired_note(name, results)
        unpaired = results.map(&:unpaired).reduce({}, :merge)
        return [] if unpaired.empty?

        ["#{name}: #{unpaired.map { |index, reason| "task #{index} unpaired: #{reason}" }.join("; ")}"]
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
         "  isolation: #{isolation_label}", *confine_field, *attempts_field, *subset_field].join("\n")
      end

      def attempts_field
        @attempts == 1 ? [] : ["  #{@attempts} attempts per task; tables fold all, paired section uses the first"]
      end

      def subset_field = @subset.stated? ? [@subset.line(@tasks.size)] : []

      def confine_field = @confine.nil? ? [] : ["  confine:   #{@confine}"]

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

      # ONE {Compare::Cost::Unpriced} ARM REFUSES THE WHOLE SECTION -- every value
      # here answers `#refuses?` itself, so this sends one message rather than
      # testing which of {Measured}/{Compare::Cost::Unpriced}/{Unmeasured} it was
      # handed. An unpriceable model makes every arm's dollar figure equally
      # unknowable, so there is no single arm's row left to render. An
      # {Unmeasured} arm never refuses the section: it renders its OWN row,
      # per {#table}, because a sibling arm's real, measured distribution
      # under the same metric must not be hidden behind this arm's honest
      # zero -- exactly the comparison a table carrying a gap for the priced
      # arms and a figure for the one that could not price would also invite,
      # which is why {Compare::Cost::Unpriced} still refuses everything.
      def section(label, measured_arms)
        folds = measured_arms.map { |(name, dists)| [name, dists.fetch(label)] }
        refusing = folds.map(&:last).select(&:refuses?)

        refusing.any? ? refused(label, refusing) : table(label, folds)
      end

      def table(label, folds)
        fmt = METRICS.fetch(label).fetch(:fmt)
        rows = folds.map { |(name, cell)| cell.row(name, fmt) }
        notes = folds.filter_map { |(name, cell)| cell.note(name) }
        grid = Compare::Table.new(headers: Compare::ArmFold::HEADERS, rows:)
        ["#{label}\n#{grid}", *notes.map { |note| "  #{note}" }].join("\n")
      end

      # Compare's wording, so the arm report and every Compare-backed report
      # refuse an unpriced cost in one voice. No arm is named, per {#section}.
      def refused(label, refusing)
        "#{label}\n  #{Compare::Cost::Unpriced.describe(refusing)}"
      end
    end
  end
end
