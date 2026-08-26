# frozen_string_literal: true

require "yaml"

module Lain
  module Bench
    # A small suite of graded CODING tasks for comparing orchestration arms
    # across a pre-registered boundary: tasks that are procedural and
    # single-thread-friendly (a later edit depends on an earlier one, so there
    # is nothing to hand a second worker) versus tasks that are genuinely
    # independent and parallel (each subtask needs zero shared context, so N
    # workers could do them concurrently). Every task grades with a
    # {Grader::Fixture} -- no model in the loop -- against a {Trajectory}: the
    # files an arm's run produced, `path => content`.
    #
    # WRITING YOUR OWN SUITE: `bench arms` takes any fixture path, and the
    # default arms system prompt ({ArmSweep::FileBlocks::CONTRACT}) teaches the
    # answer format BY EXAMPLE, so every arm holds that example's path and body
    # before it reads your task. A `gold_files` entry colliding with it scores
    # an arm that echoes the format and does no work at all, putting a floor
    # under the column -- and a floor reads as work done where a zero reads as a
    # broken run. The committed suite is guarded by a spec that scores the
    # taught example against every task; a suite of your own is not.
    class ArmTasks
      include Enumerable

      # A checkout or packaging mistake, never user input to refuse.
      class MissingFixture < Lain::Error; end

      # A malformed fixture is a bug in the fixture to surface loudly, never a
      # task to silently skip, miscategorize or duplicate.
      class MalformedTask < Lain::Error; end

      # The pre-registered boundary this suite spans: `:procedural` tasks carry
      # a real ordering dependency; `:parallel` tasks are genuinely independent
      # subtasks with no shared context.
      CATEGORIES = %i[procedural parallel].freeze

      # kind => `->(content, value) -> Boolean`. `"contains"` is the default, a
      # bare String `gold_files` value being shorthand for it; `"excludes"` and
      # `"starts_with"` exist because a substring-ANYWHERE check cannot rule out
      # a no-op (the bug's own text still present elsewhere) or an unanchored
      # paste (the right string, wrong position in the file).
      GOLD_KINDS = {
        "contains" => ->(content, value) { content.include?(value) },
        "excludes" => ->(content, value) { !content.include?(value) },
        "starts_with" => ->(content, value) { content.start_with?(value) }
      }.freeze
      private_constant :GOLD_KINDS

      # Which kinds carry the value a satisfied gold check would look like, so
      # {.positive_content} can build a self-checking Trajectory rather than
      # re-encoding the gold a second time.
      POSITIVE_KINDS = %w[contains starts_with].freeze
      private_constant :POSITIVE_KINDS

      # What a coding task's {Grader::Fixture} scores against. Deliberately NOT
      # a real Workspace or git worktree: this suite grades the SHAPE of a
      # recorded outcome, so a live arm sweep can build one from a real run's
      # files without this suite depending on an isolation backend.
      Trajectory = Data.define(:files) do
        def content_at(path) = files.fetch(path, "")
      end

      # id, the pre-registered category, the prompt an arm would receive, the
      # gold file expectations (`path => a String, shorthand for "contains",
      # or a {"kind" => value}` spec -- see {GOLD_KINDS}), and the
      # {Grader::Fixture} built from that same gold data.
      Task = Data.define(:id, :category, :prompt, :gold_files, :grader)

      class << self
        # The value that would satisfy a gold spec's positive assertion, or the
        # spec itself when it is the bare-String shorthand.
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

      # Ids are lookup keys everywhere downstream, so a silent duplicate would
      # mean `.find` always resolves to the first and the second is unreachable
      # dead weight, never a loud error.
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
