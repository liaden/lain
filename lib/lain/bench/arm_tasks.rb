# frozen_string_literal: true

require "yaml"

module Lain
  module Bench
    # A small suite of graded CODING tasks used to compare orchestration arms
    # (the chunk-orchestration-arms-isolation plan's B12 sweep) against the
    # pre-registered boundary orchestration-experiments.md draws: tasks that
    # are procedural and single-thread-friendly (a later edit depends on an
    # earlier one, so there is nothing to hand a second worker) versus tasks
    # that are genuinely independent and parallel (each subtask needs zero
    # shared context, so N workers could do them concurrently). Every task
    # grades with a {Grader::Fixture} -- no model in the loop -- against a
    # {Trajectory}: the files an arm's run produced, `path => content`. B0
    # only builds and grades the suite; B12 wires a real arm's produced files
    # into this same shape.
    class ArmTasks
      include Enumerable

      # Raised when the fixture path does not exist -- a checkout or
      # packaging mistake, never user input to refuse. Named and path-bearing
      # like {DisclosureSweep::MissingFixture}.
      class MissingFixture < Lain::Error; end

      # Raised when a fixture task is missing a required field, names a
      # category outside {CATEGORIES}, an entry isn't a mapping, the
      # top-level `tasks:` key is absent, or two tasks share an `id` -- a
      # malformed fixture is a bug in the fixture to surface loudly, never a
      # task to silently skip, miscategorize, or duplicate.
      class MalformedTask < Lain::Error; end

      # The pre-registered boundary this suite spans
      # (orchestration-experiments.md): `:procedural` tasks carry a real
      # ordering dependency (single-thread-friendly); `:parallel` tasks are
      # genuinely independent subtasks with no shared context.
      CATEGORIES = %i[procedural parallel].freeze

      # kind => `->(content, value) -> Boolean`. `"contains"` is the default
      # (a bare String `gold_files` value is shorthand for it); `"excludes"`
      # and `"starts_with"` exist because a substring-ANYWHERE check cannot
      # rule out a no-op (the bug's own text still present elsewhere) or an
      # unanchored paste (the right string, wrong position in the file) --
      # the two gaps the review panel's adversarial probes found.
      GOLD_KINDS = {
        "contains" => ->(content, value) { content.include?(value) },
        "excludes" => ->(content, value) { !content.include?(value) },
        "starts_with" => ->(content, value) { content.start_with?(value) }
      }.freeze
      private_constant :GOLD_KINDS

      # Which kinds carry the "positive" value a satisfied gold check would
      # actually look like -- used by {.positive_content} to build a
      # self-checking Trajectory rather than re-encoding the gold a second
      # time.
      POSITIVE_KINDS = %w[contains starts_with].freeze
      private_constant :POSITIVE_KINDS

      # What a coding task's {Grader::Fixture} scores against: the files an
      # arm's run produced or touched, `path => content`. Deliberately NOT a
      # real Workspace or git worktree -- B0 grades the SHAPE of a recorded
      # outcome, so a spec (or later, B12's sweep) can build one from a real
      # run's files without this suite depending on an isolation backend.
      Trajectory = Data.define(:files) do
        def content_at(path) = files.fetch(path, "")
      end

      # id, the pre-registered category, the prompt an arm would receive, the
      # gold file expectations (`path => a String, shorthand for "contains",
      # or a {"kind" => value}` spec -- see {GOLD_KINDS}), and the
      # {Grader::Fixture} built from that same gold data.
      Task = Data.define(:id, :category, :prompt, :gold_files, :grader)

      class << self
        # The value that would satisfy a gold spec's positive assertion --
        # its `"contains"`/`"starts_with"` value, or the spec itself when it
        # is the bare-String shorthand. Lets a fixture's own spec build a
        # Trajectory that should pass every one of a task's checks without
        # re-encoding the gold a second time.
        def positive_content(spec)
          return spec unless spec.is_a?(Hash)

          spec.values_at(*POSITIVE_KINDS).compact.first
        end
      end

      # @param fixture_path [String] a committed YAML fixture of tasks (see
      #   spec/fixtures/arms/*.yml for the shape)
      def initialize(fixture_path:)
        @fixture_path = fixture_path
      end

      def each(&block)
        return to_enum(:each) unless block_given?

        tasks.each(&block)
      end

      # @return [Array<Task>] the single-thread-friendly, procedural side
      def procedural = select { |task| task.category == :procedural }

      # @return [Array<Task>] the genuinely-independent-parallel side
      def parallel = select { |task| task.category == :parallel }

      private

      def tasks
        @tasks ||= unique!(raw_tasks.each_with_index.map { |raw, index| build_task(raw, index) })
      end

      # The top-level `tasks:` key is its own failure mode, distinct from a
      # malformed INDIVIDUAL task entry -- both must raise the same named,
      # located {MalformedTask} rather than this one leaking a bare,
      # path-less `KeyError`.
      def raw_tasks
        YAML.safe_load_file(existing!(@fixture_path)).fetch("tasks")
      rescue KeyError
        raise MalformedTask, "arm fixture at #{@fixture_path} is missing the top-level `tasks:` key"
      end

      # A fixture task's `id`s are used as lookup keys everywhere downstream
      # (this spec's own `.find { |t| t.id == ... }`, and B12 later) -- a
      # silent duplicate would mean `.find` always resolves to the first and
      # the second is unreachable dead weight, never a loud error.
      def unique!(built)
        duplicates = built.map(&:id).tally.select { |_id, count| count > 1 }.keys
        return built if duplicates.empty?

        raise MalformedTask, "arm fixture at #{@fixture_path} has duplicate task id(s): #{duplicates.join(", ")}"
      end

      # Every `#fetch` a malformed task could trip -- its own top-level
      # fields and its `gold_files` -- happens IN THIS METHOD, inside the one
      # `rescue KeyError`, so every shape of malformed task gets the same
      # named-and-located {MalformedTask} (the same reasoning
      # `DisclosureSweep#build_task` documents) rather than a bare, task-less
      # KeyError surfacing later at grade time. The entry-shape guard runs
      # first: a YAML entry that parses to a bare String (not a mapping) has
      # no `#fetch` at all, so it must be caught explicitly rather than
      # surfacing as a `NoMethodError`.
      def build_task(raw, index)
        raise MalformedTask, "arm fixture at #{@fixture_path} entry #{index} is not a mapping: #{raw.inspect}" \
          unless raw.is_a?(Hash)

        Task.new(**task_fields(raw))
      rescue KeyError => e
        raise MalformedTask, "arm task #{raw["id"].inspect} at #{@fixture_path} is missing #{e.key.inspect}"
      end

      def task_fields(raw)
        id = -raw.fetch("id").to_s
        gold_files = Canonical.normalize(raw.fetch("gold_files"))
        { id:, category: validated_category(raw), prompt: -raw.fetch("prompt").to_s,
          gold_files:, grader: build_grader(id, gold_files) }
      end

      def validated_category(raw)
        category = raw.fetch("category").to_sym
        return category if CATEGORIES.include?(category)

        raise MalformedTask, "arm task #{raw["id"].inspect} at #{@fixture_path} names unrecognized category " \
                             "#{category.inspect} (expected one of #{CATEGORIES})"
      end

      # One hard assertion per gold check (a task's gold_files entry may
      # carry more than one -- {#gold_checks}): does the trajectory's content
      # at that path satisfy it? A {Grader::Fixture}'s `#why` names every
      # check that failed, so a partial-credit run (e.g. two of three
      # independent files touched) is legible, not just pass/fail.
      def build_grader(id, gold_files)
        Grader::Fixture.new("#{id} matches gold") do |f|
          gold_files.each do |path, spec|
            gold_checks(path, spec).each do |description, predicate|
              f.check(description) { |trajectory| predicate.call(trajectory.content_at(path)) }
            end
          end
        end
      end

      # A bare String spec is shorthand for a single `"contains"` check; a
      # Hash spec (e.g. `{"contains" => ..., "excludes" => ...}`) can compose
      # more than one kind against the same path -- see {GOLD_KINDS}.
      def gold_checks(path, spec)
        normalized = spec.is_a?(Hash) ? spec : { "contains" => spec }
        normalized.map do |kind, value|
          template = GOLD_KINDS.fetch(kind) do
            raise MalformedTask, "arm fixture at #{@fixture_path} names unknown gold kind #{kind.inspect} for #{path}"
          end
          ["#{path} #{kind} #{value.inspect}", ->(content) { template.call(content, value) }]
        end
      end

      def existing!(path)
        raise MissingFixture, "no arm-task fixture at #{path}" unless File.file?(path)

        path
      end
    end
  end
end
