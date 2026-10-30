# frozen_string_literal: true

module Lain
  class Journal
    class Projection
      # Which message records belong to each spawn, and which of them ended it. A spawn's lineage
      # is the spawn and every {Telemetry::Message} whose `from`, `to` or `causal_parents` names a
      # record already in it, so it reads off the records' own fields with no Store.
      #
      # Membership grows by a record's own digest only. A spawn's causal parent is the parent's
      # head, and absorbing it would pull the parent's whole chain into the lineage.
      #
      # It declares no `combine`: a record joins a lineage through one that landed before it, so
      # two halves folded apart lose every link that crosses the cut.
      class Lineage < Projection
        # One spawn's lineage.
        #
        # @!attribute [r] records
        #   @return [Array<Telemetry::Message>] the spawn first, then each member in the order it landed
        # @!attribute [r] completions
        #   @return [Array<String>] the digests of the members that ended the spawn
        Followed = Data.define(:records, :completions) do
          # @return [Boolean] whether a member ended the spawn
          def complete? = completions.any?

          # A member ends only the spawn it cites, so a grandchild's completion, which chains to
          # the child through the grandchild's spawn, does not end the child.
          #
          # @param record [Telemetry::Message]
          # @param spawn [String] the digest of the spawn this lineage follows
          # @return [Followed]
          def with(record, spawn)
            ends = record.kind == :message && record.causal_parents.include?(spawn) && ends?(record)
            Followed.new(records: [*records, record], completions: [*completions, *(record.digest if ends)])
          end

          private

          def ends?(record)
            lifecycle = StatusFeed::SpawnLifecycle.new(record)
            lifecycle.terminal? || lifecycle.finished?
          end
        end

        NOT_FOLLOWED = Followed.new(records: [], completions: [])
        NO_SPAWNS = [].freeze

        # @return [Lineage]
        def self.unit = new({ lineages: {}, owners: {} })

        # Only the lineages a record joins are rebuilt; every other one is carried over as the same
        # frozen value, and which ones it joins is read off the owners index, never by scanning spawns.
        #
        # @param record [Telemetry::Journalable, Telemetry::Untyped]
        # @return [Lineage] self for a record that joins no lineage
        def step(record)
          return self unless record.is_a?(Telemetry::Message)

          spawns = joined(record)
          return self if spawns.empty?

          stepped = spawns.to_h { |spawn| [spawn, self[spawn].with(record, spawn)] }
          self.class.new(lineages: lineages.merge(stepped),
                         owners: owners.merge(record.digest => spawns))
        end

        # @return [Hash{String=>Followed}] each spawn's lineage by the spawn's digest
        def value = lineages

        # @param spawn [String] a spawn's digest
        # @return [Followed] {NOT_FOLLOWED} for a spawn never seen
        def [](spawn) = lineages.fetch(spawn, NOT_FOLLOWED)

        # @param spawn [String] a spawn's digest
        # @param digest [String] a record's digest
        # @return [Boolean] whether the record is in the spawn's lineage
        def member?(spawn, digest) = spawns_owning(digest).include?(spawn)

        # @param digest [String] a member's digest
        # @yieldparam digest [String] when no spawn's lineage ends with it
        # @return [String] the digest of the spawn the member ended, or what the block answers
        def completing(digest)
          spawns_owning(digest).find(-> { yield digest }) { |spawn| self[spawn].completions.include?(digest) }
        end

        private

        def lineages = state.fetch(:lineages)

        def owners = state.fetch(:owners)

        def spawns_owning(digest) = owners.fetch(digest, NO_SPAWNS)

        def joined(record)
          own = record.kind == :spawn ? [record.digest] : []
          cited = [record.digest, record.from, record.to, *record.causal_parents].compact
          (own + cited.flat_map { |digest| spawns_owning(digest) }).uniq
        end
      end
    end
  end
end
