# frozen_string_literal: true

module Lain
  class Workspace
    class Snapshot
      module Scope
        class ShadowGit
          # One turn's two trees: the project staged just before its tools ran
          # and just after. Their difference is exactly what the turn changed --
          # a deletion and a mode change included, which a snapshot's file map
          # cannot say -- and nothing the human did between turns, which lands
          # in the before-tree.
          class TreePair
            # A nested repository is a commit id, not a blob; there are no bytes
            # to read, and {Revert} refuses the path by its mode anyway.
            GITLINK_MODE = "160000"

            # @param repository [Repository] the store both trees live in
            # @param before [String] the tree staged at the turn's prime
            # @param after [String] the tree staged at its settle
            def initialize(repository:, before:, after:)
              @repository = repository
              @before = before
              @after = after
            end

            # A pair exists even for a turn whose trees did not move: its undo
            # is still planned from the trees, not from the file map.
            def staged? = true

            def moved? = @before != @after

            # @return [Array<String>] the root-relative paths the turn changed
            def keys = rows.map(&:key)

            # @return [Array<Revert::Move>] one per changed path, bytes resolved
            def moves
              rows.map do |row|
                Revert::Move.new(key: row.key, before: side(row.before_id, row.before_mode),
                                 after: side(row.after_id, row.after_mode))
              end
            end

            # A path the trees cannot speak for, because git never staged it.
            def ignored?(key) = @repository.ignored?(key)

            private

            def rows = @rows ||= @repository.rows(@before, @after)

            def side(id, mode)
              id && Revert::Side.new(bytes: mode == GITLINK_MODE ? "" : @repository.blob(id), mode:)
            end
          end
        end
      end
    end
  end
end
