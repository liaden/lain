# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # The one fact a set-aside recording must be able to state.
      class RecordingFailed < Declarative::Carrier
        NAMED = {
          error_class: "must name what stopped the run"
        }.freeze

        attribute :error_class, :lain_interned
        attribute :message, :lain_interned
        validates :error_class, presence: { message: "must name what stopped the run, got nil" }

        validate :names_are_not_blank

        private

        # The interning cast turns false, [] and {} into present Strings, so blankness is judged on the raw value.
        def names_are_not_blank
          NAMED.each do |name, text|
            raw = @attributes[name.to_s].value_before_type_cast
            errors.add(name, "#{text}, got #{raw.inspect}") if raw.blank? && !errors.include?(name)
          end
        end
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

      def initialize(error_class:, message:) = super(**Carriers::RecordingFailed.settle!(error_class:, message:))

      # @param error [Exception]
      # @return [RecordingFailed]
      def self.of(error) = new(error_class: error.class.name, message: error.message)
    end
  end
end
