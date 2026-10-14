# frozen_string_literal: true

module Lain
  module Telemetry
    # The files one tool round wrote, as a human would name them: relative to
    # the project root, absolute elsewhere, an epic document as `<slug>/<path>`.
    # One record per round, sent to the journal and to the display channel, so
    # the transcript can show a write the moment the round settles.
    FilesWritten = Data.define(:role, :paths) do
      include Journalable

      def initialize(role:, paths:)
        super(role: role.to_s.dup.freeze, paths: paths.map { |path| path.to_s.dup.freeze }.freeze)
      end
    end
  end
end
