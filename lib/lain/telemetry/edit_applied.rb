# frozen_string_literal: true

module Lain
  module Telemetry
    # The lines an `edit_file` call took out and put in, cut to what the display
    # will show; `hidden` counts the lines the cut left out, both sides together.
    # Display only in practice: the full edit is already in the turn's tool call.
    EditApplied = Data.define(:path, :removed, :added, :hidden) do
      include Journalable

      def initialize(path:, removed:, added:, hidden:)
        super(path: path.to_s.dup.freeze, removed: removed.map { |line| line.to_s.dup.freeze }.freeze,
              added: added.map { |line| line.to_s.dup.freeze }.freeze, hidden:)
      end
    end
  end
end
