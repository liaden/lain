# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Two names and one positive Integer COUNT, never content: `Data` freezes the record but not
      # its members, so a Hash of leaked bytes would otherwise pass.
      class OverMasked < Declarative::Carrier
        attribute :tool, :lain_interned
        attribute :shape, :lain_interned
        attribute :spans
        validates :tool, :shape, presence: { message: "must be a name, got nil" }
        validates :spans, numericality: { only_integer: true, greater_than: 0,
                                          message: "must be a positive Integer, got %<value>s" }
        validates :tool, :shape, raw_present: { message: "must be a name" }
      end
    end

    # A tool result masked whole where a scan could not finish one shape: which tool, which shape,
    # and how many spans, never which bytes. Counted apart from {CommandRedacted} and its kin,
    # because these spans are masked on suspicion and a human reads the rate as a cost of scanning.
    OverMasked = Data.define(:tool, :shape, :spans) do
      include Journalable

      # The count stays untyped so numericality judges what the caller gave before it becomes an Integer.
      def initialize(tool:, shape:, spans:)
        settled = Carriers::OverMasked.settle!(tool:, shape:, spans:)
        super(**settled, spans: settled.fetch(:spans).to_i)
      end
    end
  end
end
