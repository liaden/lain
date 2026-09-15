# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # The one fact a set-aside recording must be able to state.
      class RecordingFailed < Declarative::Carrier
        attribute :error_class
        validates :error_class, presence: { message: "must name what stopped the run, got nil" }
      end
    end

    # Why a recorded bench run was set aside, written into that run's own file
    # by {Bench::CLI::RunRecorder} before the rename, so the file says it rather
    # than only the terminal that watched it. `bench variance` reads it back
    # when it lists the run.
    #
    # The error's class NAME and its message, and nothing else: no byte of the
    # conversation rides a record about how the conversation ended.
    RecordingFailed = Data.define(:error_class, :message) do
      include Journalable

      def initialize(error_class:, message:)
        Carriers::RecordingFailed.check!(error_class:)

        super(error_class: error_class.to_s.dup.freeze, message: message.to_s.dup.freeze)
      end

      # @param error [Exception]
      # @return [RecordingFailed]
      def self.of(error) = new(error_class: error.class.name, message: error.message)
    end
  end
end
