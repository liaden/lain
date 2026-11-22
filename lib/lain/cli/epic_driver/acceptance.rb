# frozen_string_literal: true

module Lain
  module CLI
    module EpicDriver
      # How an issue's work is judged, parsed once from its declared level so
      # no later code compares a level name: by failing tests the red step
      # writes and runs, or by a human at the implementation gate.
      module Acceptance
        COMMAND = /`([^`]+)`/
        ACTED = %w[When Then].freeze
        CONTINUING = %w[And But].freeze
        private_constant :ACTED, :CONTINUING

        Tested = Data.define(:level) do
          def placed_by_layout? = true

          def manual_commands = nil

          # @param tests [#call] the project's red step
          def red_step(tests) = tests
        end

        Manual = Data.define(:commands) do
          def initialize(commands:) = super(commands: commands.map(&:-@).freeze)

          def placed_by_layout? = false

          def manual_commands = commands

          def red_step(_tests) = IssueTests::Unscripted
        end

        # @param level [String, nil] the issue's declared level
        # @param scenarios [Array<Gherkin::Scenario>] the issue's criteria
        # @return [Tested, Manual]
        def self.of(level, scenarios:)
          return Tested.new(level:) unless level == TestLayout::MANUAL

          Manual.new(commands: commands_in(scenarios))
        end

        # @param issue [Epic::Issue]
        # @return [Tested, Manual]
        def self.of_issue(issue) = of(issue.level, scenarios: Gherkin::Criteria.parse(issue.criteria).scenarios)

        # The whole When and Then clauses, because a procedure written in prose names no backticked command.
        #
        # @param scenarios [Array<Gherkin::Scenario>]
        # @return [Array<String>]
        def self.procedure(scenarios) = scenarios.flat_map { |scenario| acted(scenario.clauses) }

        def self.commands_in(scenarios) = procedure(scenarios).flat_map { |text| text.scan(COMMAND).flatten }.uniq

        # A Given is setup, so a span in it is not a command the human runs;
        # an And or But belongs to the keyword before it.
        def self.acted(clauses)
          keywords = clauses.map(&:keyword).inject([]) do |seen, word|
            seen << (CONTINUING.include?(word) ? seen.last : word)
          end
          clauses.zip(keywords).filter_map { |clause, word| clause.text if ACTED.include?(word) }
        end
        private_class_method :commands_in, :acted
      end
    end
  end
end
