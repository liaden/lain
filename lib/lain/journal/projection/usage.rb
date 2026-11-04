# frozen_string_literal: true

module Lain
  class Journal
    class Projection
      # What each command and role spent, summed over the session's {Telemetry::TurnUsage} records.
      # Every record is a payment, so none is deduplicated, and no other record carries tokens, so
      # none is counted twice.
      #
      # A record names the role that paid; one that names none was the requester's, or the agent's.
      # A record under no skill line files under a nil command, which a reader shows as it likes.
      class Usage < Projection
        AGENT = Requester.main.name

        # @return [Usage]
        def self.unit = new({})

        # @param record [Telemetry::Journalable, Telemetry::Untyped]
        # @return [Usage] self for a record that is not a payment
        def step(record)
          return self unless record.is_a?(Telemetry::TurnUsage)

          self.class.new(state.merge({ [record.command, paid_by(record)] => spent(record) }) do |_, held, new|
            held + new
          end)
        end

        # @param other [Usage]
        # @return [Usage] both halves' sums, pointwise
        def combine(other) = self.class.new(state.merge(other.state) { |_, mine, theirs| mine + theirs })

        private

        def paid_by(record) = record.role || record.requester || AGENT

        def spent(record) = ::Lain::Usage.new(**record.usage.transform_keys(&:to_sym))
      end
    end
  end
end
