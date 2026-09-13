# frozen_string_literal: true

require "digest"
require "fileutils"

# {Paths::Shipped} first: {Paths}'s own class body below composes
# {Paths::NVIM_PLUGIN_ROOT} from it, so the child must be loaded before the
# parent's body runs rather than after, which is where a sibling-subtree
# require usually goes (see {Prompt}'s own index for that usual shape) --
# here load order runs the other way.
require_relative "paths/shipped"

module Lain
  # Paths come off a subprocess's stdout, `Dir.children` and `File.realpath` as
  # bytes; the filesystem's own encoding is what they have to be tagged with to
  # compare equal to the same path read any other way. Declared once, here,
  # because it is a fact about paths and nothing else -- three copies of it had
  # accumulated, each with its own fan-out of callers reaching for a different
  # one.
  FILESYSTEM = Encoding.find("filesystem")

  # XDG Base Directory resolution, every path suffixed `/lain` so this harness
  # never collides with a sibling tool sharing the same base. Project-scoped
  # `.lain/` is a separate, non-XDG concern; {ProjectDir} is its locator.
  #
  # {ProjectDir} sits on BOTH sides of that line and reads this class for the
  # half that is XDG: the state feed it resolves is rewritten every turn, which
  # makes it machine state rather than a project artifact, so it is composed
  # from {#state_home} and {#project_hash} rather than written into the user's
  # source tree.
  #
  # `env:` is injected rather than read globally, so a spec builds an isolated
  # Hash instead of mutating process-wide state -- the real `$HOME` is never
  # touched by this class or by its specs.
  class Paths
    # A directory this class had to create and could not.
    class Unwritable < Error
      def initialize(path, cause)
        super("cannot create #{path}: #{cause.message}")
      end
    end

    # Every XDG accessor falls back to `$HOME`, so a non-absolute `$HOME` makes
    # all of them relative -- and a relative state path resolves against the
    # process's cwd, which puts machine state back inside the user's repository.
    #
    # **Not {Project::Resolver::UnusableHome}, and not interchangeable with it.**
    # That one guards a home used as the STOP of an upward project walk and is
    # strictly narrower: it also refuses `"/"`, because a root of `/` makes every
    # directory on the machine a project. This one guards a home used as a JOIN
    # BASE, where `/` works fine -- `$HOME=/` is what root gets in a container,
    # and `/.local/state/lain` is a real answer. So `$HOME=/` is ACCEPTED here
    # and REFUSED there, deliberately. Two classes rather than one because load
    # order forces it: `paths.rb` precedes `project.rb` in the manifest, so this
    # file cannot name that one.
    class NonAbsoluteHome < Error
      def initialize(value)
        super("$HOME is #{value.inspect}, which is not an absolute path -- " \
              "lain resolves its XDG directories under it and cannot use a relative one. " \
              "Export an absolute HOME, or set XDG_STATE_HOME/XDG_CONFIG_HOME/XDG_CACHE_HOME.")
      end
    end

    # The ONE naming authority for a session's response WAL: `<stem>.wal` beside
    # the NDJSON path, stem taken by stripping WHATEVER extension the given path
    # carries, not a hardcoded ".ndjson". {CLI::Chronicle#spool} writes it and
    # {CLI::Resume::Salvager} reads it back after a crash, so the derivation
    # lives in one place rather than as string surgery in each. A class method
    # because the transform is pure and needs no XDG env.
    def self.wal_for(ndjson_path)
      stem = File.basename(ndjson_path, ".*")
      File.join(File.dirname(ndjson_path), "#{stem}.wal")
    end

    # The ephemeral (--btw) session convention. The session header is
    # write-once, so ephemerality cannot be a header field -- it lives in the
    # FILENAME instead: `<ts>-<pid>.btw.ndjson`. {wal_for} strips only the final
    # extension, so the derived wal carries the mark too and the pair travels
    # together. ArgumentError rather than a refusal on a mismarked path, because
    # a wrong mark here is a caller bug and never user input.
    BTW_MARK = ".btw.ndjson"

    def self.ephemeral?(path) = File.basename(path).end_with?(BTW_MARK)

    def self.ephemeral_for(ndjson_path)
      raise ArgumentError, "#{ndjson_path} already carries the .btw mark" if ephemeral?(ndjson_path)
      raise ArgumentError, "#{ndjson_path} is not an .ndjson path to mark .btw" unless ndjson_path.end_with?(".ndjson")

      "#{ndjson_path.delete_suffix(".ndjson")}#{BTW_MARK}"
    end

    def self.promoted_for(path)
      raise ArgumentError, "#{path} carries no .btw mark to strip" unless ephemeral?(path)

      "#{path.delete_suffix(BTW_MARK)}.ndjson"
    end

    # One ephemeral session's lifecycle: {#promote!} keeps it, {#reap!} drops it.
    # The record itself is never rewritten -- only renamed -- which is what keeps
    # the write-once header honest and the owning appender's fd valid across a
    # promotion. A crash runs neither, so both files survive for salvage.
    class Ephemeral
      # A promotion target that already exists. POSIX `rename` silently
      # replaces its target, so without this guard a promotion could destroy
      # an unrelated durable session's record -- refused loudly instead, and
      # BEFORE any rename runs, so a refused promotion changes nothing.
      class Collision < Error
        def initialize(target)
          super("promotion would overwrite #{target}, which already exists; refusing to destroy a record")
        end
      end

      # @param path [String] the `.btw.ndjson` journal path
      # @param filesystem [#rename, #exist?, #delete] injectable so a spec can
      #   pin the rename ORDER and simulate a crash between the two renames
      def initialize(path, filesystem: File)
        raise ArgumentError, "#{path} carries no .btw mark; only an ephemeral session promotes or reaps" \
          unless Paths.ephemeral?(path)

        @path = path
        @filesystem = filesystem
      end

      # WAL FIRST, then journal. The crash window then leaves
      # `<stem>.btw.ndjson` + `<stem>.wal`: the journal still wears the mark, so
      # the state is visibly unfinished and a re-run completes it. The reverse
      # order would leave a promoted `<stem>.ndjson` whose recorded frames sit in
      # a `.btw.wal` basename {Paths.wal_for} no longer derives -- a
      # normal-looking session that silently lost its salvage pair.
      #
      # Both {Collision} guards fire before ANY rename runs, so a refused
      # promotion cannot itself manufacture the half-promoted state.
      #
      # @return [String] the promoted journal path
      # @raise [Collision] when either target name already exists
      def promote!
        promoted = Paths.promoted_for(@path)
        clobber!(promoted)
        promote_wal!(promoted)
        @filesystem.rename(@path, promoted)
        promoted
      end

      # WAL first here too: dying mid-reap then leaves a journal with no wal
      # (salvage finds no frames -- an ordinary state), never an orphan wal no
      # journal names. The wal may not exist at all -- it opens lazily, on the
      # first spooled frame.
      def reap!
        [Paths.wal_for(@path), @path].each { |file| @filesystem.delete(file) if @filesystem.exist?(file) }
      end

      private

      # Skipped entirely when the marked wal is absent -- the never-spooled
      # lazy case AND the crash-window retry, where the wal already wears the
      # promoted name and only the journal leg remains.
      def promote_wal!(promoted)
        wal = Paths.wal_for(@path)
        return unless @filesystem.exist?(wal)

        clobber!(Paths.wal_for(promoted))
        @filesystem.rename(wal, Paths.wal_for(promoted))
      end

      def clobber!(target)
        raise Collision, target if @filesystem.exist?(target)
      end
    end

    # Where the gem ships its own nvim plugin. Kept as a constant here (rather
    # than only on {Shipped}) because it is part of this class's PUBLIC shape --
    # `spec/lain/cli/up_spec.rb` names `Lain::Paths::NVIM_PLUGIN_ROOT` directly --
    # so this stays the one spelling and {Shipped} is where the value now comes
    # from, not a second copy of it.
    NVIM_PLUGIN_ROOT = Shipped::NVIM_PLUGIN_ROOT

    # `nvim_plugin_root:` is injectable, mirroring {Core::Child}'s `binary:`, so
    # a spec can point at a path that does not exist without disturbing the real
    # gem tree.
    def initialize(env: ENV, nvim_plugin_root: NVIM_PLUGIN_ROOT)
      @env = env
      @nvim_plugin_root = nvim_plugin_root
    end

    attr_reader :nvim_plugin_root

    # The user's home directory, from the INJECTED env -- the base every XDG
    # accessor falls back to, and the anchor {Sensitivity} classifies against.
    # Public because the path classifier needs a home a spec can pin; it reads
    # no filesystem and creates nothing, so exposing it hands out a naming and
    # no authority.
    #
    # `Dir.home` goes through {#present} TOO, closing the return leg of the same
    # defect: Ruby's `Dir.home` hands back `$HOME` verbatim with no absoluteness
    # check, and this class defaults `env: ENV`, so a relative `$HOME` was read
    # twice, failed the first guard, and came back through the fallback
    # unexamined -- making every XDG accessor relative and resolving
    # {ProjectDir#state_path} against the repository this class exists to keep
    # clean. Refusing beats degrading: there is no home to invent.
    #
    # @return [String]
    # @raise [NonAbsoluteHome] when neither the env nor `Dir.home` is absolute
    def home
      present(@env["HOME"]) || present(Dir.home) || raise(NonAbsoluteHome, @env["HOME"] || Dir.home)
    end

    def config_home = xdg_dir("XDG_CONFIG_HOME", ".config")
    def cache_home = xdg_dir("XDG_CACHE_HOME", ".cache")
    def state_home = xdg_dir("XDG_STATE_HOME", ".local/state")

    # The XDG spec gives runtime dirs no `$HOME`-relative fallback, so the
    # ROADMAP settles on `/tmp/lain` rather than inventing one.
    def runtime_dir
      base = present(@env["XDG_RUNTIME_DIR"]) || "/tmp"
      File.join(base, "lain")
    end

    # The same recipe DEBUGGING_NVIM.md gives for the nvim socket path, so a
    # project resolves to one identifier everywhere: `sha256(realpath)[0,12]`.
    #
    # Kernel-resolved, not merely expanded: nvim's getcwd() and Ruby's Dir.pwd
    # BOTH resolve symlinks, so a symlinked path ARGUMENT (`--project <symlink>`)
    # hashed lexically would name a different socket/session id than the editor
    # serves. Isolation keys WORKER IDS through here too -- strings naming no
    # real path -- so an unresolvable argument falls back to the lexical
    # expansion instead of raising. That fallback is hash-UNSTABLE by
    # construction: `link/app` hashes lexically while `app` does not exist and
    # post-resolution once it does, so an answer taken for a path that is not
    # there yet is provisional. Unreachable for {ProjectDir#state_path}, whose
    # callers pass a checked directory or `Dir.pwd`.
    def project_hash(dir = Dir.pwd)
      Digest::SHA256.hexdigest(resolved(dir))[0, 12]
    end

    # The one XDG path this harness writes durable state into, so it is the one
    # accessor that ensures the directory exists rather than leaving creation to
    # the caller -- {Journal.open}'s mkdir_p-then-own pattern.
    def sessions_dir(project: project_hash)
      ensure_dir(File.join(state_home, "sessions", project))
    end

    # The cross-project harness-improver sink: ONE file, not partitioned by
    # project_hash the way {#sessions_dir} is -- a dogfood note about lain
    # ITSELF is worth keeping across every project lain has run in, unlike a
    # session's own turn history. It ensures the dir because {Improvement::Sink}
    # opens this path directly, per append, with no mkdir step of its own.
    def improvements_path
      File.join(ensure_dir(state_home), "improvements.ndjson")
    end

    private

    # Expansion first (`~`, relative segments), THEN kernel resolution, so the
    # fallback hashes the same lexical form realpath would have started from.
    # The rescue covers the RESOLUTION only: `File.expand_path` itself raises
    # ArgumentError on an unknown `~user`, which is deliberately not caught --
    # that is a malformed name rather than an absent directory, and no CLI door
    # reaches this method with one.
    def resolved(dir)
      expanded = File.expand_path(dir)
      File.realpath(expanded)
    rescue SystemCallError
      expanded
    end

    def xdg_dir(var, fallback)
      File.join(present(@env[var]) || File.join(home, fallback), "lain")
    end

    # The XDG Base Directory spec: a non-absolute value is invalid and MUST be
    # ignored, so relative folds into the same treat-as-unset branch as empty.
    def present(value) = value&.start_with?("/") ? value : nil

    def ensure_dir(path)
      FileUtils.mkdir_p(path)
      path
    rescue SystemCallError => e
      raise Unwritable.new(path, e)
    end
  end
end
