# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # The cwd is a path, interned.
      class WritesUnread < Declarative::Carrier
        attribute :tool_use_id
        attribute :cwd, :lain_interned
      end
    end

    # A bash command lain could not read, so whatever it wrote has no
    # {FileWritten} record. The freshness check reads it as a change under
    # every root, since the writes it stands for could have landed anywhere.
    #
    # Written however the call ended, a timeout included: a killed command
    # may already have written.
    #
    # Durable journal only; nothing on the display shows it.
    WritesUnread = Data.define(:tool_use_id, :cwd) do
      include Journalable

      # @param tool_use_id [String] the `tool_use` block that ran the command
      # @param cwd [String] the directory the command ran in
      def initialize(tool_use_id:, cwd:)
        settled = Carriers::WritesUnread.settle!(tool_use_id:, cwd:)

        super(**settled, tool_use_id: -settled[:tool_use_id].to_s)
      end
    end
  end
end
