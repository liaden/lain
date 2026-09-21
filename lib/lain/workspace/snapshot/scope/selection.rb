# frozen_string_literal: true

module Lain
  class Workspace
    class Snapshot
      module Scope
        # What a scope chose out of a write set: the paths to capture, and the
        # ones it refused for falling outside the snapshot's root. Both halves
        # ride back from ONE call because asking twice is not free -- a detecting
        # scope stages a tree to answer -- and because the omission is only
        # reportable by whoever saw the paths it dropped.
        #
        # Enumerable over the KEPT paths, which is all {Snapshot} captures; the
        # other half travels to {Agent::SnapshotSlot}, the one object on this
        # path that can journal.
        #
        # Containment is LEXICAL -- `expand_path`, no symlink resolution -- and
        # that is a decision with a cost. {Lain::Session::Confined#holds?}, the
        # authority {Middleware::ConfineToScope} admits a write by, resolves the
        # REALPATH of the longest existing prefix, and says in its own note why
        # lexical would be wrong for a gate. So the two can disagree: a write
        # the gate admitted because it really lands under the spike, spelled
        # through a symlink, is lexically outside and is dropped here. Neither
        # is the bug. A gate must answer about where bytes will land, because a
        # symlink out of the scope is how a confined write escapes; a snapshot
        # KEY must match {Snapshot#relative}, which is `Pathname` and lexical,
        # because the same content at two roots has to hash identically for
        # cross-machine replay. Resolving here and keying there would let a path
        # pass containment and still key `../`, which is the wedge this test
        # exists to prevent.
        #
        # The consequence, stated so it is not discovered: with a root spelled
        # through a symlink, every write can land outside lexically, and such a
        # turn snapshots nothing -- {Snapshot#write} refuses to record an empty
        # map it did not earn, and the slot journals the drop.
        Selection = Data.define(:kept, :outside) do
          include Enumerable

          # Splits `paths` at the root boundary.
          #
          # @param paths [Enumerable<String>] candidate absolute paths
          # @param root [String, Pathname] the snapshot's root
          # @return [Selection]
          def self.within(paths, root)
            base = File.expand_path(root.to_s)
            kept, outside = paths.to_a.uniq.partition { |path| inside?(File.expand_path(path), base) }
            new(kept:, outside:)
          end

          # The separator is what tells a path under the root from a sibling
          # whose name merely begins with it: /w-2/a is not inside /w. Joined
          # with an empty segment rather than concatenated, which is also how
          # the scope gate spells it, so a root of "/" stays "/" instead of
          # becoming a "//" nothing matches.
          def self.inside?(path, base) = path == base || path.start_with?(File.join(base, ""))
          private_class_method :inside?

          # Deeply frozen here rather than in the factory, so a hand-built
          # Selection is as shareable as a split one.
          def initialize(kept:, outside:)
            super(kept: deeply_frozen(kept), outside: deeply_frozen(outside))
          end

          def each(&) = kept.each(&)

          # `include Enumerable` lands above Data in the ancestry, so Enumerable's
          # own #to_h -- which would read the kept paths as key/value pairs and
          # raise -- shadows the value's. A Data's members are what to_h means,
          # and the matcher that walks a frozen value's children asks for them.
          define_method(:to_h, Data.instance_method(:to_h))

          private

          # A copy, as {Telemetry::ToolOutput} freezes its own String: the
          # caller's write-set is not ours to freeze in place.
          def deeply_frozen(paths) = paths.map { |path| path.dup.freeze }.freeze
        end
      end
    end
  end
end
