# frozen_string_literal: true

module Lain
  class LiveSessions
    # One running chat, as the review queue needs to find it. `input_socket` and
    # `journal` are nil for a headless or `--no-journal` chat.
    Record = Data.define(:session_id, :pid, :start, :host, :root, :cwd, :input_socket, :journal, :attended,
                         :started_at) do
      # @param fields [Hash{String=>Object}] a parsed record file
      # @return [Record]
      def self.from_h(fields) = new(**members.to_h { |member| [member, fields.fetch(member.to_s)] })

      # @return [Hash{String=>Object}]
      def to_h = super.transform_keys(&:to_s)

      # @return [Liveness::Writer] the process that wrote the record, for {Liveness::Writer#verdict}
      def writer = Liveness::Writer.new(pid:, start:, host:)
    end
  end
end
