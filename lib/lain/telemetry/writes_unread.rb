# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # The cwd is a path, interned.
      class WritesUnread < Declarative::Carrier
        attribute :tool_use_id
        attribute :cwd, :lain_interned
        attribute :command, default: nil
      end
    end

    # A bash command lain could not read, so whatever it wrote has no
    # {FileWritten} record. The freshness check reads it as a change under
    # every root, since the writes it stands for could have landed anywhere.
    #
    # Written however the call ended, a timeout included: a killed command
    # may already have written. It keeps the command as the model wrote it,
    # which the journal holds already in the call's input, so a later build's
    # bar can name it; a record from before it named one reads back with none.
    #
    # Durable journal only; nothing on the display shows it.
    WritesUnread = Data.define(:tool_use_id, :cwd, :command) do
      include Journalable

      # @param tool_use_id [String] the `tool_use` block that ran the command
      # @param cwd [String] the directory the command ran in
      # @param command [String, nil] the command, as written
      def initialize(tool_use_id:, cwd:, command: nil)
        settled = Carriers::WritesUnread.settle!(tool_use_id:, cwd:, command:)

        super(**settled, tool_use_id: -settled[:tool_use_id].to_s, command: settled[:command]&.then { -_1.to_s })
      end

      def to_journal = omitting_defaults(super, Carriers::WritesUnread, :command)
    end
  end
end
