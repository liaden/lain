# frozen_string_literal: true

module Lain
  module Gherkin
    # GG-2: the glue between an APPROVED {Criteria} (G2 owns the gate; this class
    # trusts what it is handed) and the `test_engineer` role. Renders the
    # `gherkin-tests` skill scaffold -- shipped, static, states the red-first
    # contract -- inlines the MECHANICAL scenarios and the caller-named
    # framework, and dispatches the whole prompt through {Skill::RoleSpawn} to
    # `test_engineer` in fresh-context mode: a fresh child sees exactly this
    # scaffold, never the parent's conversation.
    #
    # Scenarios flagged `mechanical: false` (the `# rubric` marker, G1) are
    # excluded from the prompt entirely and handed back as `rubric_scenarios` --
    # they are human-judged, not testable, and G2's routing decides what happens
    # to them next. This class only carries the split forward, verbatim (GG-4's
    # split, recorded here, not improvised downstream).
    #
    # No framework detection lives here on purpose: `framework:` is the
    # caller's job (G4's TestHarness owns detection); this class only NAMES it
    # in the prompt.
    class TestGeneration
      # Raised by {#call} when EVERY scenario in the Criteria is rubric-flagged
      # (`mechanical: false`): there is nothing left to hand `test_engineer`, and
      # spawning a child with an empty scenario section would be a silent no-op
      # -- indistinguishable, from the caller's side, from "generated nothing
      # because nothing needed generating." Loud beats both a silent spawn and
      # an implicit "the caller already checked" precondition, matching the
      # parser's own empty-``` gherkin ```-block doctrine ({MalformedBlock}).
      # Names the criteria digest so the caller can trace which Criteria was empty.
      class NothingMechanical < Error; end

      SKILL = :"gherkin-tests"
      private_constant :SKILL

      # Wraps {Skill::RoleSpawn}'s one-shot result rather than replacing it --
      # `role_spawn.rb` is not this wave's file to edit, so the extra fields
      # (the criteria digest, the rubric split) ride ALONGSIDE its return
      # rather than inside it. Deeply frozen: `result` is already a frozen
      # {Tool::Result}, `criteria_digest` is `Canonical.digest`'s frozen String,
      # and `rubric_scenarios` holds already-frozen {Scenario}s behind a frozen
      # Array.
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

          #{mechanical_scenarios.map { |scenario| render_scenario(scenario) }.join("\n\n")}
        PROMPT
      end

      def render_scenario(scenario)
        clauses = scenario.clauses.map { |clause| "  #{clause.keyword} #{clause.text}" }
        (["Scenario: #{scenario.name}"] + clauses).join("\n")
      end
    end
  end
end
