# frozen_string_literal: true

require "mixlib/shellout"
require "securerandom"

module Lain
  class Workspace
    class Snapshot
      module Scope
        # Everything the project's working tree changed during a turn, detected
        # by a git repository LAIN owns, unioned with the write-set the
        # structured tools recorded. This closes the gap {WriteSet}'s note
        # declares: a free-form `bash` enumerates nothing, so the only way to
        # learn what it touched is to ask the filesystem -- and git honours the
        # project's own `.gitignore` while doing it.
        #
        # This class decides what a snapshot captures; every git call is its
        # {Repository}'s. Git is the CHANGE DETECTOR: the bytes a snapshot
        # records still land in lain's blake3 {Store} through {Snapshot}.
        #
        # The store is a BARE repository under XDG state, keyed by
        # {Paths#project_hash}, driven with `GIT_DIR` pointed at it and
        # `GIT_WORK_TREE` at the project. Never anything colocated: `.git/` in
        # the user's tree is THEIRS, and a detector that wrote objects into it,
        # refreshed its index, or moved its HEAD would corrupt real work to
        # observe it. Asking their repository is also wrong more quietly -- a
        # commit they make between turns moves the baseline, and the paths the
        # agent touched stop being reported at all.
        #
        # Every invocation SCRUBS the inherited git context ({GIT_CONTEXT_SCRUB})
        # before setting its own. A lain launched from a git hook inherits
        # `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY` and friends, and each one
        # would redirect a write back into the repository being hooked: the scrub
        # is what makes "GIT_DIR is the sole authority" true rather than intended.
        #
        # Each turn is measured from its OWN prime: {#baseline} stages the tree
        # just before the turn's tools run, and the settle stages it again after.
        # Anything the human did between turns lands in the first tree, never in
        # the turn's delta -- measuring from the previous turn's end would hand
        # their edits to the next turn, and an undo of it would revert them.
        # {#pair} is those two trees, and their difference is exactly the turn.
        #
        # The union is what makes this scope a strict widening of {WriteSet}: a
        # posture buys its safety from reversibility, so swapping the scope must
        # never capture LESS. The two halves have DIFFERENT blind spots, which is
        # why both stay and why {NOTE} spells the consequence out.
        class ShadowGit
          # A git invocation that did not deliver an answer. Loud, and carrying
          # git's own stderr, because the alternative reading of a failed detector
          # is "no files changed" -- a silence that leaves a turn unsnapshotted
          # and undo unable to restore it.
          class Failed < Error
            def self.from_git(operation, shell)
              new("shadow git #{operation} failed (#{outcome(shell)}): #{shell.stderr.strip}")
            end

            # git missing from PATH, or mixlib's own timeout: no exit status
            # exists to report, so the exception names itself instead.
            def self.from_error(operation, error)
              new("shadow git #{operation} failed (#{error.class}): #{error.message}")
            end

            # Mixlib reports a NIL exit status for a child that died on a signal,
            # and `nil.zero?` is a NoMethodError in place of the refusal. The OOM
            # killer reaping `add --all` on a large tree is the realistic case,
            # and exactly when git's stderr is worth having.
            def self.outcome(shell)
              shell.exitstatus.nil? ? "killed by signal" : "exit #{shell.exitstatus}"
            end
            private_class_method :outcome
          end

          NOTE = "shadow git + write-set: the UNION of two detectors with different blind spots. " \
                 "A lain-owned bare repo under XDG state reports what changed in the project work " \
                 "tree during the turn, including out-of-band writes (e.g. bash), but it " \
                 "cannot see inside a path the project's .gitignore excludes, nor inside a " \
                 "submodule; the recorded write-set sees only what structured tools wrote. So a " \
                 "gitignored path is captured only if a structured tool wrote it, and a bash write " \
                 "inside a submodule is not captured at all. A write by another process during a " \
                 "turn's tool window counts as that turn's change, and undoing the turn removes it. " \
                 "The project's own repository is never read or written."

          # The git-context env that redirects where git finds its repository,
          # index and objects. Mapping each to `nil` DELETES it in the forked
          # child (the {WorkerEnv} scrub semantics mixlib honours), which keeps a
          # lain running under a git hook from staging into the hooked
          # repository's index or spilling objects into its store.
          #
          # `GIT_CONFIG_COUNT`/`GIT_CONFIG_PARAMETERS` go too: they are an
          # invoking git's `-c` overrides passed down transiently, the same
          # inheritance class as `GIT_DIR`, and can set `core.worktree` or
          # `core.bare` under us. `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM`
          # deliberately DO NOT -- honouring the user's real global config is
          # what makes their `core.excludesFile` apply to what we capture.
          GIT_CONTEXT_SCRUB = {
            "GIT_DIR" => nil, "GIT_INDEX_FILE" => nil, "GIT_WORK_TREE" => nil,
            "GIT_PREFIX" => nil, "GIT_COMMON_DIR" => nil, "GIT_NAMESPACE" => nil,
            "GIT_OBJECT_DIRECTORY" => nil, "GIT_ALTERNATE_OBJECT_DIRECTORIES" => nil,
            "GIT_CONFIG_COUNT" => nil, "GIT_CONFIG_PARAMETERS" => nil
          }.freeze

          def self.for(paths:, session:) = new(paths:, session:)

          # Inert: construction shells no git and touches no filesystem, so a
          # scope resolved from its short name is safe to build anywhere. The
          # work starts at {#baseline}.
          #
          # @param paths [Paths] resolves XDG state and the per-project key
          # @param session [String] names this session's index in the shared
          #   store; a slot hands every scope it builds the same one
          # @param shell_out_factory [#call] builds the subprocess runner,
          #   injected as a factory, as {Isolation::Worktree} does
          def initialize(paths: Paths.new, session: SecureRandom.hex(6),
                         shell_out_factory: Mixlib::ShellOut.public_method(:new))
            @paths = paths
            @session = session
            @shell_out_factory = shell_out_factory
            @repositories = {}
            @trees = {}
            @before = {}
          end

          # Stage `root` as it stands now: the tree the next turn is measured
          # from. Keyed by root, so two roots never share one -- and the
          # constructor takes no root at all, which keeps "primed against A,
          # asked about B" unrepresentable.
          #
          # @param root [String, Pathname] the workspace root
          # @return [String] the staged tree id
          # @raise [Failed] when any git invocation does not deliver an answer
          def baseline(root)
            expanded = expand(root)
            @before[expanded] = @trees[expanded] = repository(expanded).stage
          end

          # @param root [String, Pathname] the workspace root
          # @return [TreePair, NoTrees] the tree the last prime staged and the
          #   one the last settle staged; NoTrees for a root never primed
          def pair(root)
            expanded = expand(root)
            return NoTrees unless @before.key?(expanded)

            TreePair.new(repository: repository(expanded), before: @before[expanded], after: @trees.fetch(expanded))
          end

          # A shadow map records only what its turn touched, so an unequal map is
          # no evidence of change: the trees are. A path a structured tool wrote
          # that git never stages -- a .gitignore'd one -- is the one change only
          # the map can see.
          def unchanged?(root:, files:, last:)
            !pair(root).moved? && files.all? { |key, digest| (last || {})[key] == digest }
          end

          # @param write_set [Enumerable<String>] the session's recorded writes
          # @param root [String, Pathname] the workspace root {Snapshot} names
          # @return [Array<String>] absolute paths, each once
          # @raise [Failed] when any git invocation does not deliver an answer
          def paths(write_set:, root:)
            (detect(expand(root)) + write_set.to_a).uniq
          end

          def note = NOTE

          def label = "shadow_git"

          private

          def expand(root) = File.expand_path(root.to_s)

          def repository(root)
            @repositories[root] ||= Repository.open(root:, paths: @paths, session: @session,
                                                    shell_out_factory: @shell_out_factory)
          end

          # A root with no staged tree compares against the tree just staged, so
          # an unprimed start yields an empty delta by construction rather than
          # by a special case -- never every file in the project, as diffing the
          # empty tree would.
          def detect(root)
            tree = repository(root).stage
            previous = @trees.fetch(root, tree)
            @trees[root] = tree
            repository(root).changed(previous).map { |name| File.join(root, name) }
          end
        end
      end
    end
  end
end
