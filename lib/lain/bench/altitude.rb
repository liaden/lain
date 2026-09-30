# frozen_string_literal: true

require "yaml"

module Lain
  module Bench
    # The DECOMPOSITION bench: the same work entered at four heights on
    # {Arm::Ladder}, over a suite whose tasks sit on a SIZE axis, reported per
    # size. The question it exists to answer is where on that axis entering
    # higher up starts paying for itself -- a plan is overhead on a one-file
    # change and the difference between a finished epic and a mess on a large
    # one, and nothing in the repository measured where the crossover is.
    #
    # == Why it folds its own report rather than driving {Arm::Driver}
    #
    # The Driver folds ONE flat task list into its own fixed metrics and has no
    # second axis. This report needs both a size breakdown and two metrics only a
    # gated topology has (rework and round-trips), which is precisely the
    # reasoning {ArmSweep::Report} records for not being a Driver either. It
    # reuses the pieces that do fit -- {Compare::ArmFold}, {Compare::Distribution}
    # and {Compare::Table} -- so the cell order every bench report shares is
    # still owned in one place.
    #
    # {Suite} and {Subject} are separate FILES rather than nested classes,
    # because a nested class's lines count as the enclosing class's own under
    # Metrics/ClassLength -- the split {ArmSweep} already makes for
    # {ArmSweep::Recordings} and its Report.
    class Altitude
      # A checkout or packaging mistake, never user input to refuse.
      class MissingFixture < Lain::Error; end

      # A malformed fixture is a bug in the fixture to surface loudly, never a
      # task to silently skip, miscategorize or duplicate.
      class MalformedTask < Lain::Error; end

      # An arm that REFUSED to be scored, rather than one that scored badly. It
      # answers none of the metric readers, so every cell in its row reads "not
      # measured" -- which is the whole point: a 0.000 from an arm that never ran
      # is indistinguishable from one that ran and failed everything.
      Unrun = Data.define(:reason)

      # A distribution needs at least two samples; one run is a point, and
      # reporting it as a distribution invites a comparison the sample cannot
      # support. {Arm::Driver} states the same rule for the same reason.
      MINIMUM = 2

      # Said to the operator BEFORE the first arm runs, never written into the
      # report: a report is pasted into an issue, where a spend warning would
      # read as a property of the experiment rather than of the command.
      COST_WARNING = "lain bench altitude spends real API money: %<arms>d arms over %<tasks>d tasks, " \
                     "each arm asking a real provider for every task, and the epic arms driving a whole " \
                     "epic per task. Budget accordingly."

      # Every refusal an ARM can raise that means "this one cannot be measured",
      # as against one that means the report is broken. A lease holding no
      # checkout is a wiring mistake in the isolation a caller injected, so it
      # costs that arm its row and nothing else.
      UNMEASURABLE = [Arm::Epic::NeverRan,
                      Grader::LeaseHarness::NothingGraded, Grader::LeaseHarness::NoCheckout].freeze
      private_constant :UNMEASURABLE

      # What an arm's cell reads for a metric that topology does not have. Mark
      # absent, never fabricate: a 0 here would read as "measured, and it was
      # none", which for rework is a claim no linear arm ever made.
      NOT_MEASURED = "not measured"

      # Metric label => how to pull one value off a run, how to render it, and
      # (where the metric belongs to one topology) the reader a run must answer
      # for the metric to be measurable at all.
      #
      # Every `of:` is a Proc taking the run, including the ones a Symbol would
      # serve: cache-write has to reach through the Ledger, and one shape for
      # every row is what keeps {#table} from testing which kind it was handed.
      # EVERY metric declares the reader a run must answer for it to be
      # measurable at all -- not only the two an epic alone has. That uniformity
      # is what lets an {Unrun} arm, which answers none of them, read "not
      # measured" in every cell without anything here asking what class it is.
      METRICS = {
        "grader score" => { of: lambda(&:score), needs: :score,
                            fmt: ->(value) { format("%.3f", value) } },
        "total tokens" => { of: lambda(&:total_tokens), needs: :total_tokens,
                            fmt: ->(value) { format("%.1f", value) } },
        "cache write tokens" => { of: ->(run) { run.ledger.usage(run.timeline).cache_creation_input_tokens },
                                  needs: :ledger, fmt: ->(value) { format("%.1f", value) } },
        "wall-time (s)" => { of: lambda(&:elapsed), needs: :elapsed,
                             fmt: ->(value) { format("%.4f", value) } },
        "rework" => { of: lambda(&:rework_total), needs: :rework_total,
                      fmt: ->(value) { format("%.2f", value) } },
        "round-trips" => { of: lambda(&:round_trips_total), needs: :round_trips_total,
                           fmt: ->(value) { format("%.2f", value) } }
      }.freeze
      private_constant :METRICS

      # Every field a task declares, so {#build_task} reads them in one pass
      # rather than in hand-written fetches -- which is also what keeps that
      # method's every KeyError inside its own single rescue.
      #
      # The acceptance criteria an epic arm's issues are written from live with
      # the EPIC fixture (`epic/<slug>/epic.md`), which is what an epic is
      # actually driven from; a second copy here was read by nothing.
      FIELDS = %w[id size subject level prompt].freeze
      private_constant :FIELDS

      # One task on the size axis: what to ask, the project the work is done in,
      # and the level root whose tests judge it. `project` is `subject` RESOLVED
      # -- absolute, and proven to exist, by the pre-flight rather than by the
      # run.
      Task = Data.define(:id, :size, :subject, :level, :prompt, :project)

      # @param fixture_path [String] the committed suite (see spec/fixtures/altitude/tasks.yml)
      # @param arms [Array<Arm>] the topologies under comparison, lowest rung first
      # @param spawn_seam [#call] the agent factory threaded into every arm
      # @param grader [#grade] scores each run
      # @param isolation [#acquire, nil] the injected backend; nil leaves
      #   {Arm::NoIsolation}, which leases nothing
      # @param sink [#puts] where the cost warning is said; only the frontend
      #   may touch a real stream, so this is injected and defaults to the Null
      def initialize(fixture_path:, arms:, spawn_seam:, grader:, isolation: nil, sink: Sink::Null.new)
        @fixture_path = fixture_path
        @arms = Array(arms).freeze
        @spawn_seam = spawn_seam
        @grader = grader
        @isolation = isolation
        @sink = sink
      end

      # Memoized, so reporting twice is byte-identical for free -- and so a suite
      # that costs real money is never run a second time by a second read.
      #
      # @return [String] never printed here (output discipline)
      # @raise [MissingFixture, MalformedTask, Error] before any arm runs
      # @raise [Project::Trust::Untrusted] before any arm runs, naming the
      #   committed subject whose config nobody has trusted
      def report = @report ||= render

      private

      # Every refusal is raised BEFORE the warning and before the first arm, so a
      # malformed suite really does cost nothing: {Suite} reads the fixture,
      # validates every task and RESOLVES every subject project -- all of it pure
      # path work -- while `by_size` is forced, which is the line above the
      # warning rather than somewhere inside the run.
      def render
        grouped = by_size
        layouts_load(grouped.values.flatten)
        warn_of_cost(grouped.values.sum(&:size))
        [header(grouped), *grouped.map { |size, tasks| block(size, tasks) }].join("\n\n")
      end

      # Asked of the committed subject rather than at grading: a lease's copy is
      # deleted on release, so a refusal there names a path that is gone, and
      # comes after the arm has been paid for. Every untrusted subject is named
      # at once, so one round of `lain trust` clears them all.
      def layouts_load(tasks)
        projects = tasks.map(&:project).uniq
        untrusted = projects.filter_map { |project| untrusted_in(project) }
        raise Project::Trust::Untrusted, untrusted.join("\n") unless untrusted.empty?

        projects.each { |project| Config.test_layout(root: project) }
      end

      def untrusted_in(project)
        Project::Trust.for(project_dir: ProjectDir.new(root: project)).require!
        nil
      rescue Project::Trust::Untrusted => e
        e.message
      end

      def warn_of_cost(tasks) = @sink.puts(format(COST_WARNING, arms: @arms.size, tasks:))

      def header(grouped)
        ["Altitude — #{pluralize(grouped.values.sum(&:size), "task")} over " \
         "#{pluralize(grouped.size, "size")}, #{pluralize(@arms.size, "arm")} " \
         "(#{@arms.map(&:name).join(" vs ")})",
         "  fixture:   #{@fixture_path}"].join("\n")
      end

      # A count of one has to read as one: "1 sizes" makes an experiment record
      # look generated rather than written.
      def pluralize(count, word) = "#{count} #{count == 1 ? word : "#{word}s"}"

      # One size's whole block: the banner, then one titled table per metric.
      def block(size, tasks)
        runs = @arms.to_h { |arm| [arm.name, tasks.map { |task| run(arm, task) }] }
        ["== #{size} ==", *METRICS.map { |title, spec| table(title, spec, runs) }].join("\n\n")
      end

      # THE ARM WORKS IN THE TASK'S OWN SUBJECT PROJECT, and is graded by that
      # project's own suite at the level the task names. Both ride the run: the
      # arm is built once, while every task carries a different project and a
      # different level root.
      #
      # An arm that REFUSES to be scored is recorded as {Unrun} rather than
      # allowed to take the whole report down -- and rather than scored zero.
      def run(arm, task)
        arm.run(task.prompt, spawn_seam: @spawn_seam, grader: @grader,
                             isolation: isolation_for(task), grading: grading_for(task))
      rescue *UNMEASURABLE => e
        Unrun.new(reason: e.message)
      end

      # An injected backend WINS, for a caller that wants real worktree
      # isolation; absent one, each task leases a copy of its own subject --
      # already resolved and proven to exist by {Suite}.
      def isolation_for(task)
        @isolation || Subject.new(project: task.project)
      end

      # The judge for THIS task: the subject's own suite, narrowed to the level
      # root the task names, bound to whatever checkout the arm just leased.
      def grading_for(task)
        ->(lease:, **) { Grader::LeaseHarness.new(lease:, level: level_in(lease, task)) }
      end

      def level_in(lease, task)
        worker_env = lease.worker_env
        raise Grader::LeaseHarness::NoCheckout, no_checkout(task) if worker_env.nil?

        Config.test_layout(root: worker_env.cwd).mapping.level(task.level)
      end

      def no_checkout(task)
        "altitude task #{task.id.inspect} was graded through a lease holding no checkout, so its subject's " \
          "own suite had nowhere to run -- the bench leases a copy of each subject project, and an injected " \
          "isolation that leases nothing cannot be graded"
      end

      # Rows are arms, and an arm whose runs cannot answer this metric gets the
      # absent row rather than a fabricated zero -- while its SIBLINGS' real
      # figures still render, because a metric one topology lacks is not a metric
      # the table has to refuse.
      def table(title, spec, runs)
        rows = @arms.map { |arm| row(arm.name, runs.fetch(arm.name), spec) }
        "#{title}\n#{Compare::Table.new(headers: Compare::ArmFold::HEADERS, rows:)}"
      end

      def row(name, runs, spec)
        return fold.absent_row(name, count: runs.size, marker: NOT_MEASURED) unless measurable?(runs, spec)

        fold.row(name, Compare::Distribution.new(runs.map(&spec.fetch(:of))), fmt: spec.fetch(:fmt))
      end

      # A metric belongs to a topology, not to a run: a missing reader means the
      # arm never had the number, which is a different claim from zero. One
      # message, asked of every metric, so an {Unrun} arm needs no special case.
      def measurable?(runs, spec) = runs.all? { |run| run.respond_to?(spec.fetch(:needs)) }

      def fold = @fold ||= Compare::ArmFold.new

      # Reading and validating the fixture is {Suite}'s whole job, so every
      # refusal about the FILE lives there and this class only asks it for the
      # tasks, grouped onto the axis the report is built around.
      def by_size = suite.by_size

      def suite = @suite ||= Suite.new(path: @fixture_path)
    end
  end
end
