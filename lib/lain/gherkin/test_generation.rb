# frozen_string_literal: true

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
    # No framework detection lives here on purpose: `framework:` is the
    # caller's job ({Grader::TestHarness} owns detection); this class only
    # NAMES it in the prompt.
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
      Record = Data.define(:result, :criteria_digest, :rubric_scenarios) do
        def initialize(result:, criteria_digest:, rubric_scenarios:)
          super(result:, criteria_digest: -criteria_digest.to_s, rubric_scenarios: rubric_scenarios.freeze)
        end
      end

      def initialize(renderer:, role_spawn:)
        @renderer = renderer
        @role_spawn = role_spawn
      end

      # @param criteria [Criteria] an approved Criteria
      # @param framework [String] the subject's test framework, named verbatim
      #   in the prompt (no detection here)
      # @return [Record]
      def call(criteria, framework:)
        mechanical, rubric_scenarios = criteria.partition(&:mechanical)
        if mechanical.empty?
          raise NothingMechanical, "criteria #{criteria.digest} has no mechanical scenarios to generate " \
                                   "tests for -- every scenario is rubric-flagged"
        end

        result = @role_spawn.call(:test_engineer, :fresh, prompt(mechanical, framework))
        Record.new(result:, criteria_digest: criteria.digest, rubric_scenarios:)
      end

      private

      def prompt(mechanical_scenarios, framework)
        <<~PROMPT
          #{@renderer.render(SKILL)}

          ## Framework

          #{framework}

          ## Scenarios

          #{mechanical_scenarios.map(&:render).join("\n\n")}
        PROMPT
      end
    end
  end
end
