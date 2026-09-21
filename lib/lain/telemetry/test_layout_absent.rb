# frozen_string_literal: true

module Lain
  module Telemetry
    # The session wrote through a layout guard with no layout declared. Once
    # per session: enforcement is opt-in, and saying so on every write would
    # bury the record in the one fact that never changes.
    TestLayoutAbsent = Data.define(:root) do
      include Journalable

      def initialize(root:)
        super(root: root.to_s.dup.freeze)
      end
    end
  end
end
