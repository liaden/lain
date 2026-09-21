# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A `check!` rather than a `settle!` for the reason {ToolOutput}'s own
      # `bytes.freeze` gives: settling COPIES, and copying possibly-large
      # subprocess output would double it.
      class ToolOutput < Declarative::Carrier
        STREAMS = %i[stdout stderr].freeze

        attribute :stream
        validate :stream_is_known

        private

        # Bespoke rather than `inclusion:`, so the refusal keeps the hand-rolled
        # guard's exact bytes: `%<value>s` renders a Symbol un-inspected ("got
        # nope"), losing the colon that says the offender was one.
        def stream_is_known
          return if STREAMS.include?(stream)

          errors.add(:stream, "must be one of #{STREAMS.inspect}, got #{stream.inspect}")
        end
      end
    end

    # Bytes emitted by a running tool, attributed at the source rather than
    # reconstructed later. `tool_use_id`/`bytes` are frozen at construction
    # because `Data` freezes the instance but not a contained mutable String,
    # and one unfrozen ivar would make the event non-`Ractor.shareable?`.
    ToolOutput = Data.define(:tool_use_id, :stream, :bytes) do
      include Journalable

      def initialize(tool_use_id:, stream:, bytes:)
        Carriers::ToolOutput.check!(stream:)

        # bytes is frozen in place, not dup'd: copying possibly-large subprocess output would double it.
        super(tool_use_id: tool_use_id.dup.freeze, stream:, bytes: bytes.freeze)
      end
    end
  end
end
