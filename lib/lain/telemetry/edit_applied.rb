# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Lines are stringified before settling so a non-String line cannot reach the journal.
      class EditApplied < Declarative::Carrier
        attribute :path, :lain_interned
        attribute :removed, :lain_canonical
        attribute :added, :lain_canonical
        attribute :hidden
      end
    end

    # The lines an `edit_file` call took out and put in, cut to what the display
    # will show; `hidden` counts the lines the cut left out, both sides together.
    # Display only in practice: the full edit is already in the turn's tool call.
    EditApplied = Data.define(:path, :removed, :added, :hidden) do
      include Journalable

      def initialize(path:, removed:, added:, hidden:)
        super(**Carriers::EditApplied.settle!(path:, removed: removed.map(&:to_s), added: added.map(&:to_s), hidden:))
      end
    end

    class EditApplied
      WIDTH = 80
    end
  end
end
