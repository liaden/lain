# frozen_string_literal: true

require "fileutils"
require "mixlib/shellout"

module Lain
  class Workspace
    class Snapshot
      module Scope
        # Everything the project's working tree changed since the previous turn,
        # detected by a git repository LAIN owns, unioned with the write-set the
        # structured tools recorded. This is the scope that closes the gap
        # {WriteSet}'s note declares: a free-form `bash` enumerates nothing, so
        # the only way to learn what it touched is to ask the filesystem, and
        # git is the mature answer to "what changed" that also honours the
        # project's own `.gitignore`.
        #
        # Git is only the CHANGE DETECTOR. The bytes still land in lain's blake3
        # {Store} through {Snapshot}, so the workspace record stays lain's own
        # content-addressed DAG and nothing here is ever restored by git.
        #
        # == Why lain owns the repository, and where it lives
        #
        # The store is a BARE repository under XDG state, keyed by
        # {Paths#project_hash} -- `<state_home>/workspace/<project-digest>` --
        # driven with `GIT_DIR` pointed at it and `GIT_WORK_TREE` pointed at the
        # project. Never anything colocated: `.git/` in the user's tree is
        # THEIRS, and a detector that wrote objects into it, refreshed its
        # index, or moved its HEAD would corrupt real work to observe it. Asking
        # their repository instead is also wrong for a quieter reason -- a
        # commit they make between turns moves the baseline, and the paths the
        # agent touched stop being reported at all.
        #
        # Every invocation SCRUBS the inherited git context ({GIT_CONTEXT_SCRUB})
        # before setting its own. A lain launched from a git hook inherits
        # `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY` and friends, and each one
        # would redirect a write back into the repository being hooked: the
        # scrub is what makes "GIT_DIR is the sole authority" true rather than
        # merely intended.
        #
        # == The baseline, and the one turn it costs
        #
        # A delta needs something to be a delta FROM, and the honest baseline is
        # the project as the session found it -- not the last tree some previous
        # session left behind, which would attribute every edit the user made in
        # between to this session's first turn and offer to undo their work.
        # {#baseline} is that priming, and {Snapshot#initialize} calls it with
        # the same root it will name in every payload, so the SHORT NAME stays
        # usable end to end: a posture may hand `:shadow_git` through as an
        # inert Symbol and still have turn 1 covered. A scope nobody primes
        # reports the write-set only for its first turn, because there is no
        # earlier tree to compare against.
        #
        # == Why the write-set rides along
        #
        # The union is what makes this scope a strict widening of {WriteSet}: a
        # posture buys its safety from reversibility, so swapping the scope must
        # never capture LESS. The two halves have DIFFERENT blind spots, which
        # is the whole reason to keep both -- and why {NOTE} spells the
        # consequence out rather than describing one policy.
        class ShadowGit
          # A git invocation that did not deliver an answer. Loud, and carrying
          # git's own stderr, because the alternative reading of a failed
          # detector is "no files changed" -- a silence that leaves a turn
          # unsnapshotted and undo unable to restore it. Named per the
          # error-taxonomy convention: a refusal subclasses {Lain::Error} next
          # to the owner that raises it.
          class Failed < Error
            def self.from_git(operation, shell)
              new("shadow git #{operation} failed (#{outcome(shell)}): #{shell.stderr.strip}")
            end

            # git missing from PATH, or mixlib's own timeout: no exit status
            # exists to report, so the exception names itself instead.
            def self.from_error(operation, error)
              new("shadow git #{operation} failed (#{error.class}): #{error.message}")
            end

            # Mixlib reports a NIL exit status for a child that died on a
            # signal, and `nil.zero?` is a NoMethodError in place of the
            # refusal. The OOM killer reaping `add --all` on a large tree is the
            # realistic case, and it is exactly when git's stderr is worth
            # having.
            def self.outcome(shell)
              shell.exitstatus.nil? ? "killed by signal" : "exit #{shell.exitstatus}"
            end
            private_class_method :outcome
          end

          NOTE = "shadow git + write-set: the UNION of two detectors with different blind spots. " \
                 "A lain-owned bare repo under XDG state reports what changed in the project work " \
                 "tree since the previous turn, including out-of-band writes (e.g. bash), but it " \
                 "cannot see inside a path the project's .gitignore excludes, nor inside a " \
                 "submodule; the recorded write-set sees only what structured tools wrote. So a " \
                 "gitignored path is captured only if a structured tool wrote it, and a bash write " \
                 "inside a submodule is not captured at all. The project's own repository is never " \
                 "read or written."

          # The git-context env that redirects where git finds its repository,
          # index and objects. Mapping each to `nil` deletes it in the forked
          # child (the {WorkerEnv} scrub semantics mixlib honours), which is what
          # keeps a lain running under a git hook from staging into the hooked
          # repository's index or spilling objects into its store.
          #
          # `GIT_CONFIG_COUNT`/`GIT_CONFIG_PARAMETERS` go too: they are an
          # invoking git's `-c` overrides passed down transiently, the same
          # inheritance class as `GIT_DIR`, and they can set `core.worktree` or
          # `core.bare` under us. `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM`
          # deliberately DO NOT -- honouring the user's real global config is
          # what makes their `core.excludesFile` apply to what we capture.
          GIT_CONTEXT_SCRUB = {
            "GIT_DIR" => nil, "GIT_INDEX_FILE" => nil, "GIT_WORK_TREE" => nil,
            "GIT_PREFIX" => nil, "GIT_COMMON_DIR" => nil, "GIT_NAMESPACE" => nil,
            "GIT_OBJECT_DIRECTORY" => nil, "GIT_ALTERNATE_OBJECT_DIRECTORIES" => nil,
            "GIT_CONFIG_COUNT" => nil, "GIT_CONFIG_PARAMETERS" => nil
          }.freeze

          # Inert: construction shells no git and touches no filesystem, so
          # `Scope.resolve(:shadow_git)` costs nothing and a scope resolved from
          # its short name is safe to build anywhere. The work starts at
          # {#baseline}.
          #
          # @param paths [Paths] resolves XDG state and the per-project key
          # @param shell_out_factory [#call] builds the subprocess runner,
          #   injected as a factory exactly as {Isolation::Worktree} does
          def initialize(paths: Paths.new, shell_out_factory: Mixlib::ShellOut.public_method(:new))
            @paths = paths
            @shell_out_factory = shell_out_factory
            @trees = {}
          end

          # Record `root` as it stands now, so the next {#paths} is a delta from
          # here. Keyed by root, so priming twice is idempotent and two roots
          # never share one baseline -- the constructor takes no root at all,
          # which is what keeps "primed against A, asked about B" from being a
          # state this object can hold.
          #
          # @param root [String, Pathname] the workspace root
          # @raise [Failed] when any git invocation does not deliver an answer
          def baseline(root)
            expanded = expand(root)
            @trees[expanded] = stage(expanded)
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

          # A root with no recorded tree compares against the tree just staged,
          # so an unprimed start yields an empty delta by construction rather
          # than by a special case -- and reporting every file in the project,
          # which diffing the empty tree would do, is never one of the outcomes.
          def detect(root)
            tree = stage(root)
            previous = @trees.fetch(root, tree)
            @trees[root] = tree
            diff(root, previous)
          end

          # `add --all` is what honours `.gitignore` and what notices deletions;
          # `write-tree` freezes the staged state as the next turn's baseline.
          #
          # It records a SUBMODULE as a gitlink, so a bash write inside one is
          # invisible here -- exactly the blindness this scope exists to close,
          # still open for a project with submodules, and declared in {NOTE}
          # rather than papered over. When a gitlink moves, the path reported is
          # the submodule DIRECTORY, which {Snapshot#entry}'s `File.file?` guard
          # drops: right outcome, but by luck rather than by contract.
          def stage(root)
            dir = store(root)
            attempt("add") { git(dir, root, "add", "--all") }
            attempt("write-tree") { git(dir, root, "write-tree") }.stdout.strip
          end

          # `--no-renames` states a dependency rather than changing today's
          # behaviour: this plumbing ignores `diff.renames` and detects nothing
          # without an explicit `-M`, so REMOVING the flag reddens no spec --
          # the suite is not the guard here. What it guards against is `-M`
          # arriving, by hand or by a changed default, because a detected rename
          # reports only its DESTINATION and the path that vanished is exactly
          # what a restore has to know about. The "both ends of a move" example
          # is what would catch that.
          #
          # `-z` because a filename may contain a newline, and git's quoted
          # output would hand {Snapshot} a path that opens nothing.
          def diff(root, previous)
            shell = attempt("diff-index") do
              git(store(root), root, "diff-index", "--cached", "--name-only", "--no-renames", "-z", previous)
            end
            shell.stdout.split("\0").reject(&:empty?).map { |name| File.join(root, name) }
          end

          def store(root)
            File.join(@paths.state_home, "workspace", @paths.project_hash(root)).tap do |dir|
              init(dir) unless File.directory?(dir)
            end
          end

          # The init runs under the plain scrub, with no GIT_DIR of its own: the
          # directory argument is the only thing that may decide where the store
          # lands.
          def init(dir)
            ensure_state_home(File.dirname(dir))
            attempt("init") { run("init", "--bare", "--quiet", dir, environment: GIT_CONTEXT_SCRUB) }
          end

          # {Paths::Unwritable} rather than a raw `Errno`, because that is the
          # refusal {Paths} raises for every other XDG directory it creates and
          # the taxonomy is what a caller rescues. Built here rather than routed
          # through `Paths#ensure_dir`, which is private.
          def ensure_state_home(dir)
            FileUtils.mkdir_p(dir)
          rescue SystemCallError => e
            raise Paths::Unwritable.new(dir, e)
          end

          def attempt(operation)
            shell = yield
            raise Failed.from_git(operation, shell) unless shell.exitstatus&.zero?

            shell
          rescue Errno::ENOENT, Mixlib::ShellOut::CommandTimeout => e
            raise Failed.from_error(operation, e)
          end

          def git(dir, root, *)
            run("-C", root, *, environment: GIT_CONTEXT_SCRUB.merge("GIT_DIR" => dir, "GIT_WORK_TREE" => root))
          end

          def run(*, environment:)
            @shell_out_factory.call("git", *, environment:).tap(&:run_command)
          end
        end
      end
    end
  end
end
