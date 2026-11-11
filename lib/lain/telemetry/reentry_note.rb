# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # `note` is a String that may be empty: the empty one is the retraction.
      class ReentryNote < Declarative::Carrier
        attribute :note, :lain_interned
        validates :note, exclusion: { in: [nil], message: "must be a String, got nil" }
      end
    end

    # What the human left for their return, recorded so a `--resume` can say it
    # first. An empty `note` clears; {SessionRecord::Replay} keeps the latest.
    # Named apart from the approval queue's parked requests, which it is not.
    ReentryNote = Data.define(:note) do
      include Journalable

      def initialize(note:) = super(**Carriers::ReentryNote.settle!(note:))
    end
  end
end
