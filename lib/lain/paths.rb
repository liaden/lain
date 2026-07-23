# frozen_string_literal: true

require "digest"
require "fileutils"

module Lain
  # XDG Base Directory resolution: config in `$XDG_CONFIG_HOME`, caches in
  # `$XDG_CACHE_HOME`, durable state in `$XDG_STATE_HOME`, ephemera in
  # `$XDG_RUNTIME_DIR` -- each falling back to the spec-mandated default when
  # unset, every path suffixed `/lain` so this harness never collides with a
  # sibling tool sharing the same base. Project-scoped `.lain/` (like `.git/`)
  # is a separate, non-XDG concern and out of scope here.
  #
  # `env:` is injected (defaulting to the real `ENV`) rather than read globally,
  # so a spec builds an isolated Hash instead of mutating process-wide state --
  # the real `$HOME` is never touched by this class or by its specs.
  class Paths
    # Named per the error-taxonomy convention: a refusal subclasses {Lain::Error}
    # next to the owner that raises it (see {Journal::Closed}).
    class Unwritable < Error
      def initialize(path, cause)
        super("cannot create #{path}: #{cause.message}")
      end
    end

    # The ONE naming authority for a session's response WAL: `<stem>.wal`
    # beside whatever NDJSON path it sits next to, stem taken by stripping
    # WHATEVER extension the given path carries (not a hardcoded ".ndjson"
    # strip). {CLI::Chronicle#spool} and {CLI::Resume::Salvager} both derive
    # the wal path from the SAME session file for the SAME reason -- one
    # writes it, the other reads it back after a crash -- so this lives here,
    # a class method, rather than duplicated string surgery in each: a class
    # method because the transform is pure and needs no XDG env to resolve.
    def self.wal_for(ndjson_path)
      stem = File.basename(ndjson_path, ".*")
      File.join(File.dirname(ndjson_path), "#{stem}.wal")
    end

    # The ephemeral (--btw) session convention, T3. The session header is
    # write-once, so ephemerality cannot be a header field -- it lives in the
    # FILENAME instead: `<ts>-<pid>.btw.ndjson`. {wal_for} strips only the
    # final extension, so the derived wal (`<ts>-<pid>.btw.wal`) carries the
    # mark too and the pair travels together. All three transforms are pure
    # naming, class methods like {wal_for}; ArgumentError (not a refusal) on a
    # mismarked path because a wrong mark here is a caller bug, never user
    # input.
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

    # One ephemeral session's lifecycle: {#promote!} keeps it, {#reap!} drops
    # it. Both are pure filesystem renames/deletes over the pair {Paths} names
    # -- the record itself is never rewritten, which is what keeps the
    # write-once header honest and the owning appender's fd valid across a
    # promotion (rename does not disturb an open fd). A crash simply runs
    # neither, so both files survive for salvage.
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

      # WAL FIRST, then journal. The crash window between the two then leaves
      # `<stem>.btw.ndjson` + `<stem>.wal`: the journal still wears the mark,
      # so the half-promoted state is visibly unfinished and a re-run of this
      # method completes it (the wal leg is skipped once done). The reverse
      # order's window would leave a promoted `<stem>.ndjson` whose recorded
      # frames sit in a `.btw.wal` basename {Paths.wal_for} no longer derives
      # -- a normal-looking session that silently lost its salvage pair.
      #
      # Both {Collision} guards fire before ANY rename runs (a refused
      # promotion must not itself manufacture the half-promoted state): the
      # journal-target guard first, then the wal leg's own guard immediately
      # before the wal rename -- the first rename there is.
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

    def initialize(env: ENV)
      @env = env
    end

    def config_home = xdg_dir("XDG_CONFIG_HOME", ".config")
    def cache_home = xdg_dir("XDG_CACHE_HOME", ".cache")
    def state_home = xdg_dir("XDG_STATE_HOME", ".local/state")

    # No `$HOME`-relative fallback in the XDG spec for runtime dirs -- ROADMAP:600
    # settles on `/tmp/lain` rather than inventing one.
    def runtime_dir
      base = present(@env["XDG_RUNTIME_DIR"]) || "/tmp"
      File.join(base, "lain")
    end

    # The same recipe DEBUGGING_NVIM.md:17 uses for the nvim socket path, so a
    # project resolves to one identifier everywhere: `sha256(expand_path)[0,12]`.
    def project_hash(dir = Dir.pwd)
      Digest::SHA256.hexdigest(File.expand_path(dir))[0, 12]
    end

    # The one XDG path this harness actually writes durable state into, so it is
    # the one accessor that ensures the directory exists (mkdir_p-on-demand,
    # mirroring {Journal.open}'s mkdir_p-then-own pattern) rather than leaving
    # creation to the caller.
    def sessions_dir(project: project_hash)
      ensure_dir(File.join(state_home, "sessions", project))
    end

    # M6's cross-project harness-improver sink (M2): ONE file, not
    # partitioned by project_hash the way {#sessions_dir} is -- a dogfood
    # note about lain ITSELF is worth keeping across every project lain has
    # ever run in, unlike a session's own turn history. Same
    # ensure-dir-on-demand shape as {#sessions_dir}, since {Improvement::Sink}
    # opens this path directly, per append, with no separate mkdir step of
    # its own.
    def improvements_path
      File.join(ensure_dir(state_home), "improvements.ndjson")
    end

    private

    def xdg_dir(var, fallback)
      File.join(present(@env[var]) || File.join(home, fallback), "lain")
    end

    def home = present(@env["HOME"]) || Dir.home

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
