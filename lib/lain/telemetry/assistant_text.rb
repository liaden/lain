# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Untyped: the text can be a whole reply, which interning would pin for the process.
      class AssistantText < Declarative::Carrier
        attribute :text
      end
    end

    # The words a turn wrote beside its tool calls. The final text-only reply
    # reaches the screen through the frontend's response path, so this record
    # exists only for the turns that path never sees.
    AssistantText = Data.define(:text) do
      include Journalable

      def initialize(text:) = super(**Carriers::AssistantText.settle!(text: text.to_s))
    end
  end
end
