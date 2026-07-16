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
