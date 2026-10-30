# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Paths are stringified before settling so a Pathname journals as its text.
      class FilesWritten < Declarative::Carrier
        attribute :role, :lain_interned
        attribute :paths, :lain_canonical
      end
    end

    # The files one tool round wrote, as a human would name them: relative to
    # the project root, absolute elsewhere, an epic document as `<slug>/<path>`.
    # One record per round, sent to the journal and to the display channel, so
    # the transcript can show a write the moment the round settles.
    FilesWritten = Data.define(:role, :paths) do
      include Journalable

      def initialize(role:, paths:)
        super(**Carriers::FilesWritten.settle!(role:, paths: paths.map(&:to_s)))
      end
    end
  end
end
