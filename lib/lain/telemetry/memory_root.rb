# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # `root` carries no rule -- nil is the empty index's identity, not an
      # absence -- but it is declared, because `settle!` hands back exactly the
      # attributes the carrier names and the record needs both.
      class MemoryRoot < Declarative::Carrier
        attribute :turn_digest
        attribute :root
        validates :turn_digest, presence: { message: "must name the committed turn, got nil" }
      end
    end

    # The memory root in force at one committed turn. Emitted by
    # {Memory::JournalMemoryRoot} and never by the Agent, which stays
    # memory-blind throughout. Pairing the two digests is what makes recall
    # replayable: `Index#checkout(root)` reproduces exactly the snapshot this
    # turn could see, however far the live index has moved since. The name is
    # QUALIFIED -- `turn_digest`, not `digest` -- because this record carries
    # two digests, and it is the join key onto {TurnUsage}'s `digest`.
    #
    # `root` may be nil where `turn_digest` may not: an EMPTY index has no root
    # node to name, and nil IS its identity (`checkout(nil)` answers it) rather
    # than an absence.
    MemoryRoot = Data.define(:turn_digest, :root) do
      include Journalable

      # A nil `root` needs no `&.` here: `settle!` copies what it is given and
      # nil is already `Ractor.shareable?`, so absence survives untouched. But
      # `root` must still be NAMED: it carries no validation to catch an
      # accidental nil, so its keyword is the only thing standing between a
      # caller and a record that silently claims the index was empty.
      def initialize(turn_digest:, root:) = super(**Carriers::MemoryRoot.settle!(turn_digest:, root:))
    end
  end
end
