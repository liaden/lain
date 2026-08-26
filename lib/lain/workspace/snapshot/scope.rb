# frozen_string_literal: true

# The scope/ subtree's index. Its children load at the TOP because REGISTRY
# below is built and FROZEN while the module body evaluates: a child required
# after it could never register its short name.
require_relative "scope/shadow_git"

module Lain
  class Workspace
    class Snapshot
      # WHICH paths a snapshot captures, and the note that declares that policy
      # in the payload. Scope is the one axis of snapshot policy that is a study
      # variable: {WriteSet} sees only what structured tools recorded, and a
      # shadow-repo scope can see what `bash` did. Everything else -- content
      # addressing, root-relative keys, the skip logic -- is invariant and stays
      # in {Snapshot}.
      #
      # The note is the scope's own, never {Snapshot}'s: a payload declaring a
      # blind spot the writer no longer has would be a lie in the record.
      #
      # The duck. `#paths(write_set:, root:)` -> absolute paths to capture, in
      # any order ({Snapshot} sorts); its root is {Snapshot}'s own frozen
      # Pathname, handed over rather than re-derived so the scope and the
      # payload's "root" key cannot disagree. `#note` -> String, verbatim into
      # the payload's "snapshot_scope". `#label` -> short name, for journals and
      # bench arms. `#baseline(root)` -> primes what a difference-detecting scope
      # must know BEFORE the first turn, which is what lets a scope be chosen by
      # an inert Symbol and still cover turn 1: only {Snapshot} knows both the
      # root and the moment the session began. A no-op on a scope holding no such
      # state -- the Null Object arm, so no caller writes `if scope.respond_to?`.
      module Scope
        class Unknown < Error; end

        # The default: the paths structured mutating tools recorded via
        # {Session#record_write}. A free-form `bash` can mutate anything and no
        # tool can enumerate what it touched, so files outside the set are an
        # HONEST GAP -- never captured, never guessed at, declared in the note.
        # A write-set file mutated by bash IS re-captured, because
        # {Snapshot#write} hashes current bytes rather than trusting who wrote.
        class WriteSet
          NOTE = "write-set only: paths recorded via Session#record_write; " \
                 "out-of-band mutations (e.g. bash) outside that set are not captured"

          # `root` is unused -- this scope keys nothing -- but is part of the duck.
          def paths(write_set:, **) = write_set

          def note = NOTE

          def label = "write_set"

          # Nothing to prime: this scope reports what it was handed.
          def baseline(_root) = nil
        end

        REGISTRY = { write_set: WriteSet, shadow_git: ShadowGit }.freeze
        private_constant :REGISTRY

        # A name maps to a fresh instance; an already-built scope passes through.
        # Unknown names fail loudly, naming the set.
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
