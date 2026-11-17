# frozen_string_literal: true

module Lain
  class LiveSessions
    # One running chat, as the review queue needs to find it. `input_socket` and
    # `journal` are nil for a headless or `--no-journal` chat. `start` is the
    # daemon's own reading of the pid's start; what a chat registers is ignored.
    Record = Data.define(:session_id, :pid, :start, :host, :root, :cwd, :input_socket, :journal, :attended,
                         :started_at) do
      # @param fields [Hash{String=>Object}] 1 entry of session.list
      # @return [Record]
      def self.from_h(fields) = new(**members.to_h { |member| [member, fields.fetch(member.to_s)] })

      # @return [Hash{String=>Object}]
      def to_h = super.transform_keys(&:to_s)
    end
  end
end
