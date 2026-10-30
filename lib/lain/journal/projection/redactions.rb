# frozen_string_literal: true

module Lain
  class Journal
    class Projection
      # How many regions a session masked and how many it released to the model. The `lain export`
      # command and the html footer both read these 2 counts, so they come from 1 fold and cannot
      # disagree.
      class Redactions < Projection
        REDACTIONS = %w[source_masked command_redacted search_redacted].freeze
        COUNTED = [*REDACTIONS, "read_released"].freeze

        # @return [Redactions]
        def self.unit = new({ masked: 0, released: 0 })

        # @param record [Telemetry::Journalable, Telemetry::Untyped]
        # @return [Redactions] self for a record that counts toward neither
        def step(record)
          case record
          when Telemetry::SourceMasked, Telemetry::CommandRedacted, Telemetry::SearchRedacted
            self.class.new(state.merge(masked: masked + record.regions))
          when Telemetry::ReadReleased
            self.class.new(state.merge(released: released + record.regions))
          else self
          end
        end

        # @param other [Redactions]
        # @return [Redactions] the counts of both halves
        def combine(other) = self.class.new({ masked: masked + other.masked, released: released + other.released })

        # @return [Integer] regions masked as placeholders, the count the html footer shows
        def masked = state.fetch(:masked)

        # @return [Integer] regions the model was shown in clear after a release
        def released = state.fetch(:released)
      end
    end
  end
end
