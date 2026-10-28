# frozen_string_literal: true

module Lain
  module Bench
    class CompactionSweep
      # Where a sweep's model arms get their summaries. {Recorded} replays the journal and treats a
      # miss as an unanswered arm; {Local} asks a live tier and treats a failure as an error.
      module Summarizer
        # {Oracle::Recorded} in the live-tier duck. It spends nothing, so its usage is empty.
        class RecordedTier
          def initialize(recorded)
            @recorded = recorded
          end

          def ask(inputs = {}) = @recorded.ask(inputs)

          def model = "recorded"

          def usage = {}
        end
        private_constant :RecordedTier

        # Answers from the journal's recorded `oracle_answer` records alone.
        class Recorded
          # @return [#ask] a tier that answers `#ask` alone; the strategy resolver reads the full live duck
          def tier(definition, journal) = RecordedTier.new(oracle(definition, journal))

          def oracle(definition, journal, **) = Oracle::Recorded.from_journal(journal.entries, definition:)

          def loud? = false

          def name = "recorded"
        end

        # Asks a tier built by a factory, and journals each answer it gives.
        class Local
          # @param factory [#call] `->(definition) { tier }`, whose tier answers `#ask`, `#model` and `#usage`
          def initialize(factory)
            @factory = factory
          end

          def tier(definition, _journal = nil) = @factory.call(definition)

          # The live chat journals its eager answers through the same wrap, so a recorded sweep reads
          # back exactly what a summarizer handed in here wrote.
          def oracle(definition, _journal, answers_to:)
            Oracle::Recorded::Journaling.new(inner: tier(definition), definition:, journal: answers_to)
          end

          def loud? = true

          def name = "local"
        end
      end
    end
  end
end
