# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Interned, since every such record from one project names the same few directories.
      class EntryMade < Declarative::Carrier
        attribute :directory, :lain_interned
        attribute :entry
        attribute :ctime
      end
    end

    # An entry the sandbox made itself at a project's top, such as a crate's
    # first `target/`, and the ctime that left on its directory. A lineage's
    # freshness reads that ctime as the directory's own start, so the entry
    # withholds no build's grant, in this session or one resumed from it.
    #
    # Durable journal only; nothing on the display shows it.
    EntryMade = Data.define(:directory, :entry, :ctime) do
      include Journalable

      # @param directory [String] absolute; where the entry was made
      # @param entry [String] its name
      # @param ctime [Integer] the directory's ctime once the entry was made, in nanoseconds
      def initialize(directory:, entry:, ctime:)
        settled = Carriers::EntryMade.settle!(directory:, entry:, ctime:)

        super(**settled, entry: -settled[:entry].to_s, ctime: Integer(settled[:ctime]))
      end
    end
  end
end
