# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # `items` carries no rule -- an empty view is a real load, not an absence
      # -- but it is declared, because `settle!` hands back exactly the
      # attributes the carrier names and the record needs both. The version is
      # required: a load that cannot say which store version it read is the one
      # thing a later reader cannot reconstruct.
      class MemoryLoaded < Declarative::Carrier
        attribute :version
        attribute :items
        validates :version, presence: { message: "must name the store version that was read, got nil" }
      end
    end

    # The memory a session started from: the project store version it read, and
    # the items that version held, with their bodies.
    #
    # ONE PER SESSION FILE, written ahead of the first {MemoryRoot} it
    # explains. The bodies are carried rather than addressed because this
    # record is what makes a session file self-contained about memory: a
    # resume folds the recorded writes onto this seed and renders exactly what
    # was recorded, without opening the project store and without inheriting
    # what other chats have written since.
    #
    # It is NOT a compaction record. Project memory and compaction are separate
    # subsystems -- a `compaction_cut` says what one chat's own history was
    # replaced with, and nothing in either reads the other's records.
    MemoryLoaded = Data.define(:version, :items) do
      include Journalable

      # @param loaded [#version, #items] a {Memory::ProjectStore::Loaded}
      def self.of(loaded) = new(version: loaded.version, items: loaded.items.map(&:payload))

      # `items` goes through {Canonical.normalize} rather than a `dup`: the
      # record must stay deeply frozen, and these are nested Hashes a shallow
      # freeze would leave writable one level down.
      def initialize(version:, items:)
        Carriers::MemoryLoaded.check!(version:, items:)

        super(version: -version.to_s, items: Canonical.normalize(items))
      end
    end
  end
end
