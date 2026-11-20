# frozen_string_literal: true

module Lain
  module LiveSessions
    # One running chat, as the review queue needs to find it. `input_socket` and
    # `journal` are nil for a headless or `--no-journal` chat. `start` is the
    # daemon's own reading of the pid's start; what a chat registers is ignored.
    # `project_poll` is a request the chat makes at registration; the daemon's listing does not carry it.
    Record = Data.define(:session_id, :pid, :start, :host, :root, :cwd, :input_socket, :journal, :attended,
                         :started_at, :project_poll) do
      # @param project_poll [Boolean] whether the chat asks the daemon to poll its project's github settings
      # @param fields [Hash{Symbol=>Object}] the other members
      def initialize(project_poll: false, **fields) = super

      # @param fields [Hash{String=>Object}] 1 entry of session.list
      # @return [Record]
      def self.from_h(fields)
        new(**(members - [:project_poll]).to_h { |member| [member, fields.fetch(member.to_s)] })
      end

      # @return [Hash{String=>Object}]
      def to_h = super.transform_keys(&:to_s)
    end
  end
end
