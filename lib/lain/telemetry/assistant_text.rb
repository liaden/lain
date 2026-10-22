# frozen_string_literal: true

module Lain
  module Telemetry
    # The words a turn wrote beside its tool calls. The final text-only reply
    # reaches the screen through the frontend's response path, so this record
    # exists only for the turns that path never sees.
    AssistantText = Data.define(:text) do
      include Journalable

      def initialize(text:)
        super(text: text.to_s.dup.freeze)
      end
    end
  end
end
