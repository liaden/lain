# frozen_string_literal: true

# This file is the scope/ subtree's index. Its children load at the TOP because
# REGISTRY below is built and FROZEN while the module body evaluates: a child
# required after it could never register its short name, and `Scope.fetch` would
# raise Unknown for a scope that is sitting right there.
require_relative "scope/shadow_git"

module Lain
  class Workspace
    class Snapshot
      # WHICH paths a snapshot captures, and the note that declares that policy
      # in the payload. Scope is the one axis of snapshot policy that is a study
      # variable: {WriteSet} sees only what structured tools recorded, and a
      # shadow-repo scope can see what `bash` did. Everything else about a
      # snapshot -- content addressing, root-relative keys, the skip logic --
      # is invariant, so it stays in {Snapshot}.
      #
      # The note is the scope's own, never {Snapshot}'s: a payload that declares
      # a blind spot the writer no longer has would be a lie in the record, and
      # the record naming its own scope is the whole point of the field.
      #
      # == The duck
      #
      # - `#paths(write_set:, root:)` -> Enumerable<String> of absolute paths to
      #   capture. `write_set` is the session's write-set as {Snapshot#write}
      #   received it; `root` is {Snapshot}'s own frozen Pathname root, handed
      #   over rather than re-derived so the scope and the payload's "root" key
      #   cannot disagree. Order is free -- {Snapshot} sorts.
      # - `#note` -> String, verbatim into the payload's "snapshot_scope".
      # - `#label` -> short String name, for journals and bench arms.
      # - `#baseline(root)` -> primes whatever the scope must know about the
      #   workspace BEFORE the first turn runs. {Snapshot#initialize} calls it
      #   with the root it will name in every payload, and that is what lets a
      #   scope be chosen by an inert Symbol and still cover turn 1: a
      #   difference-detecting scope needs something to be a difference FROM,
      #   and only {Snapshot} knows both the root and the moment the session
      #   began. A no-op on a scope holding no such state -- the Null Object
      #   arm, so no caller ever writes `if scope.respond_to?`.
      module Scope
        class Unknown < Error; end

        # Today's policy, and the default: the paths structured mutating tools
        # (edit_file, write_file) recorded via {Session#record_write}. A
        # free-form `bash` can mutate anything and no tool can enumerate what it
        # touched, so files outside the set are an HONEST GAP -- never captured,
        # never guessed at, and declared in the note. The one thing this scope
        # does promise about out-of-band writes: a write-set file mutated by
        # bash IS re-captured, because {Snapshot#write} hashes current bytes
        # rather than trusting who wrote them.
        class WriteSet
          NOTE = "write-set only: paths recorded via Session#record_write; " \
                 "out-of-band mutations (e.g. bash) outside that set are not captured"

          # `root` is unused here -- this scope keys nothing itself -- but is
          # part of the uniform scope duck.
          def paths(write_set:, **) = write_set

          def note = NOTE

          def label = "write_set"

          # Nothing to prime: this scope reports what it was handed, so there is
          # no earlier state for a later turn to differ from.
          def baseline(_root) = nil
        end

        REGISTRY = { write_set: WriteSet, shadow_git: ShadowGit }.freeze
        private_constant :REGISTRY

        # A name maps to a fresh instance; an already-built scope passes
        # through. Unknown names fail loudly, naming the set -- the same posture
        # {Tool::SpawnPolicy}'s strategies and {Toolset#only} take.
        def self.fetch(name)
          klass = REGISTRY.fetch(name.to_sym) do
            raise Unknown, "unknown snapshot scope #{name.inspect}, expected one of #{REGISTRY.keys.inspect}"
          end
          klass.new
        end

        def self.resolve(scope)
          scope.respond_to?(:note) ? scope : fetch(scope)
        end
      end
    end
  end
end
