# frozen_string_literal: true

require "digest"

module Lain
  module Gherkin
    # The glue between an APPROVED {Criteria} (the approval gate lives
    # elsewhere; this class trusts what it is handed) and the `test_engineer`
    # role. Dispatches through {Skill::RoleSpawn} in fresh-context mode, so the
    # child sees exactly this scaffold and never the parent's conversation.
    #
    # Scenarios flagged `mechanical: false` (the `# rubric` marker) are excluded
    # from the prompt entirely and handed back as `rubric_scenarios` -- they are
    # human-judged, not testable. This class only carries the split forward,
    # verbatim, rather than leaving it to be improvised downstream.
    #
    # Tests go where the project's {TestLayout} says: the prompt names the one
    # target path the layout mirrors from the subject at the level asked for.
    # Afterwards the call compares the target with what was there before the
    # spawn and asks the layout guard about it, so a result says both whether
    # the child did the work and whether the work sits where the guard will
    # accept it. The layout also names the framework, so no detection lives
    # here.
    class TestGeneration
      # Raised by {#call} when EVERY scenario in the Criteria is rubric-flagged
      # (`mechanical: false`): spawning a child with an empty scenario section
      # would be a silent no-op, indistinguishable from the caller's side from
      # "generated nothing because nothing needed generating". Loud beats both
      # that and an implicit "the caller already checked" precondition, the same
      # doctrine {MalformedBlock} applies to an empty gherkin fence. Names the
      # criteria digest so the caller can trace which Criteria was empty.
      class NothingMechanical < Error; end

      SKILL = :"gherkin-tests"
      private_constant :SKILL

      # Wraps {Skill::RoleSpawn}'s one-shot result rather than replacing it: the
      # extra fields ride ALONGSIDE its return, not inside it. Deeply frozen --
      # `result` is already a frozen {Tool::Result}, `criteria_digest` is
      # `Canonical.digest`'s frozen String, and `rubric_scenarios` holds
      # already-frozen {Scenario}s behind a frozen Array.
      #
      # `before` and `after` are the target's digests either side of the
      # spawn, nil where it did not exist; `verdict` is the guard's reading of
      # the target afterwards. A misplaced or missing test is a report, not a
      # raise: the caller decides whether it is fatal.
      Record = Data.define(:result, :criteria_digest, :rubric_scenarios, :target, :before, :after, :verdict) do
        def initialize(result:, criteria_digest:, rubric_scenarios:, target:, before:, after:, verdict:)
          super(result:, criteria_digest: -criteria_digest.to_s, rubric_scenarios: rubric_scenarios.freeze,
                target: target.dup.freeze, before: before&.dup&.freeze, after: after&.dup&.freeze, verdict:)
        end

        def missing? = after.nil?
        def created? = before.nil? && !after.nil?
        def changed? = !before.nil? && !after.nil? && before != after

        # The child wrote the target, and the guard accepts what it wrote or
        # refuses it only as `:no_source`: tests are generated before their
        # implementation, so a correctly placed test for a class that does not
        # exist yet is the outcome asked for. A target left as it was reads
        # false even when a sibling was written.
        def generated? = (created? || changed?) && (!verdict.refused? || verdict.rule == :no_source)
      end

      # @param renderer [Skill::Renderer] renders the `gherkin-tests` scaffold
      # @param role_spawn [#call] dispatches the test_engineer child, as
      #   {Skill::RoleSpawn} does
      # @param guard [TestLayout::Guard] over the checkout the child writes
      #   into; its layout places the target and its verdict judges it
      def initialize(renderer:, role_spawn:, guard:)
        @renderer = renderer
        @role_spawn = role_spawn
        @guard = guard
      end

      # @param criteria [Criteria] an approved Criteria
      # @param subject [String] the source file the tests are for, relative to the root
      # @param level [String] a level the layout declares
      # @return [Record]
      # @raise [TestLayout::Unplaceable] before anything is spawned, when the
      #   layout has nowhere to put the subject's tests
      def call(criteria, subject:, level:)
        mechanical, rubric_scenarios = criteria.partition(&:mechanical)
        if mechanical.empty?
          raise NothingMechanical, "criteria #{criteria.digest} has no mechanical scenarios to generate " \
                                   "tests for -- every scenario is rubric-flagged"
        end

        target = @guard.layout.mapping.test_path(subject, level:)
        before = digest(target)
        result = @role_spawn.call(:test_engineer, :fresh, prompt(mechanical, subject, level, target))
        Record.new(result:, criteria_digest: criteria.digest, rubric_scenarios:, target:, before:,
                   after: digest(target), verdict: @guard.check_file(target))
      end

      private

      def digest(target)
        path = File.join(@guard.root, target)
        File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil
      end

      def prompt(mechanical_scenarios, subject, level, target)
        <<~PROMPT
          #{@renderer.render(SKILL)}

          ## Framework

          #{@guard.layout.preset.name}

          ## Target

          Write every test below into `#{target}`: the file this project's test layout mirrors from
          `#{subject}` at the #{level} level. Not a sibling file, and not another directory.

          ## Scenarios

          #{mechanical_scenarios.map(&:render).join("\n\n")}
        PROMPT
      end
    end
  end
end
