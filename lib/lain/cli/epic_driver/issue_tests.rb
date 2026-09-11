# frozen_string_literal: true

module Lain
  module CLI
    module EpicDriver
      # An issue's red step, run in the checkout its actor holds before the
      # actor's first turn: tests generated from the issue's approved criteria
      # into the file the project's test layout mirrors from the subject, run
      # there, and committed on the checkout's branch only once they fail.
      #
      # Every refusal stops the issue with nothing committed. A project with no
      # `[tests]` table is refused rather than handed a layout detected from
      # its files, because enforcement is opt-in: a detected preset would
      # impose level roots the project never declared. Tests that pass before
      # any work is done are refused too. They check nothing the work will
      # change, so the criteria or the generation are wrong, and a human has
      # to look.
      class IssueTests
        class NoLayout < Error; end
        class NotGenerated < Error; end
        class AlreadyGreen < Error; end
        class Uncommitted < Error; end

        # What the step left: the generation's record, the failing run, and the
        # commit holding the tests.
        Red = Data.define(:record, :run, :sha)

        # @param renderer [Skill::Renderer] renders the test-writing scaffold
        # @param role_spawn [Skill::RoleSpawn] the run's role spawn; its
        #   test_engineer child is lent the held checkout rather than leasing one
        # @param harness [#call] `root -> #run`, the suite runner over a checkout
        # @param shell_out_factory [#call] builds the git subprocess runner
        def initialize(renderer:, role_spawn:, harness: Lain::Grader::TestHarness.public_method(:new),
                       shell_out_factory: Lain::Shell::Out.public_method(:new))
          @renderer = renderer
          @role_spawn = role_spawn
          @harness = harness
          @shell_out_factory = shell_out_factory
        end

        # @param criteria [Gherkin::Criteria] the issue's approved criteria
        # @param worker_env [WorkerEnv] the held checkout, on the issue's branch
        # @param subject [String] the source file the tests are for, relative to
        #   the checkout
        # @param level [String, nil] a level the layout declares; its default
        #   level when nil
        # @return [Red]
        # @raise [NoLayout, NotGenerated, AlreadyGreen, Uncommitted]
        def call(criteria, worker_env, subject:, level: nil)
          guard = Lain::TestLayout::Guard.new(layout: declared(worker_env.cwd), root: worker_env.cwd)
          record = generated(criteria, worker_env, guard, subject:, level: level || default_level(guard.layout))
          Red.new(record:, run: failing(record, worker_env), sha: commit(worker_env.cwd, record))
        end

        private

        def declared(root)
          layout = Lain::Config.test_layout(root:)
          return layout if layout.in_force?

          raise NoLayout, "#{root} declares no test layout, so the issue's failing tests have nowhere the " \
                          "layout guard would accept them: add a [tests] table to .lain/config.toml naming " \
                          "its preset and source roots"
        end

        def default_level(layout)
          level = layout.mapping.default_level
          return level.name unless level.nil?

          raise NoLayout, "the [tests] table declares no level whose tests mirror their sources, so there is " \
                          "no level to generate the issue's tests at"
        end

        def generated(criteria, worker_env, guard, subject:, level:)
          record = Lain::Gherkin::TestGeneration.new(renderer: @renderer, role_spawn: @role_spawn.within(worker_env),
                                                     guard:).call(criteria, subject:, level:)
          return record if record.generated?

          raise NotGenerated, "the test_engineer child left no tests the layout accepts at #{record.target} " \
                              "(#{record.verdict}), so nothing was committed"
        end

        def failing(record, worker_env)
          run = @harness.call(worker_env.cwd).run(worker_env, paths: [record.target])
          return run unless run.clean?

          raise AlreadyGreen, "#{record.target} ran #{run.total} examples and none failed before any work was " \
                              "done, so they check nothing the work will change: the criteria or the " \
                              "generation are wrong, and nothing was committed"
        end

        # The target alone, even when the child left other files, so the red
        # commit holds the tests and nothing else. `--no-verify` because the
        # commit fails by design: a hook that runs the suite would refuse
        # exactly the state this step exists to record.
        def commit(root, record)
          git = Lain::Isolation::Checkout.new(root, shell_out_factory: @shell_out_factory)
          committed!(git.run("add", "--", record.target))
          committed!(git.run("commit", "--no-verify", "-q", "-m", message(record), "--", record.target))
          git.head.stdout.strip
        end

        def committed!(shell)
          return if shell.exitstatus.zero?

          raise Uncommitted, "git refused the failing tests' commit: #{shell.stderr.strip}"
        end

        def message(record) = "test: failing tests at #{record.target}, from criteria #{record.criteria_digest}"
      end
    end
  end
end
