# frozen_string_literal: true

module Lain
  module Tools
    class Subagent < Tool
      class Lineage
        # How many identical one-shot spawns a session has made, by their plain
        # body, so the k-th gets adoption ordinal k. It lives on the Seam
        # because a role spawn builds a fresh Subagent, and so a fresh {Lineage},
        # per call: a count kept in the writer would start over for each.
        #
        # Counted from the session's own spawns, never from the Store, so a
        # replay or resume issuing the same spawns in order resolves the same
        # digests. Unsynchronized, and safe only because nothing between the
        # read and the write suspends the fiber.
        class Twins
          def initialize = @counts = Hash.new(0)

          # @param key [Hash] a spawn body, before any adoption mark
          # @return [Integer] 1 for the first spawn of that body
          def next(key) = @counts[key.dup.freeze] += 1

          # @return [Twins] itself, so every writer given it shares one count
          def scoped = self

          # For a seam nobody wired a session registry into: each writer counts
          # alone, as a bare {Lineage} always has.
          module Null
            def self.scoped = Twins.new
          end
        end
      end
    end
  end
end
