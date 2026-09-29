# frozen_string_literal: true

module Lain
  Project = Data.define(:root, :cwd, :kind, :detected_by) do
    include Declarative

    # `File.realpath` resolves symlinks AND requires the path to exist,
    # deliberately: a Project names a real place on disk, and a loud raise beats
    # the lexical fallback `Paths#resolved` uses, which would silently change
    # what "cwd is under root" means.
    #
    # It can also raise on a path that DOES exist (EACCES on an unreadable
    # ancestor, e.g. `/proc/1/root` under a normal user), so the raw
    # `SystemCallError` is renamed to `Unresolvable` rather than escaping
    # exe/lain's `rescue Lain::Error` as a backtrace at a user who asked for a
    # status report. Root and cwd resolve separately so a refusal can name WHICH
    # role failed, not merely that one did.
    def initialize(root:, cwd:, kind:, detected_by:)
      resolved_root = resolve!(:root, root)
      resolved_cwd = resolve!(:cwd, cwd)
      self.class.check!(root: resolved_root, cwd: resolved_cwd, kind:, detected_by:)
      super(root: -resolved_root, cwd: -resolved_cwd, kind:, detected_by:)
    end

    private

    def resolve!(role, path)
      File.realpath(path)
    rescue SystemCallError => e
      raise self.class::Unresolvable.new(role, path, e)
    end
  end

  # Reopened rather than folded into the `Data.define` block above: a `class`
  # keyword or bare constant written INSIDE that block is scoped to its lexical
  # position -- this file, i.e. `Lain` -- not to the Data-defined class
  # (CLAUDE.md, Known traps).
  #
  # Sent, not stored, exactly like {Workspace} and {WorkerEnv}: a Project rides a
  # run's Session/Context, never the Timeline, so which project a turn ran under
  # never enters a digest.
  #
  # `detected_by` is not decoration for a log line -- it is the rung detection
  # climbed to find this Project, and the consent rule branches on it directly.
  #
  # `declare do ... end` lives HERE, below {KINDS}/{DETECTED_BY}: this block's
  # lexical nesting is `[Project, Lain]`, so those resolve by bare name with
  # nothing to defer.
  #
  # `check!` and not `settle!`: `root`/`cwd` are INTERNED (`-`) below, which a
  # settled copy would turn back into an ordinary frozen dup -- shareable either
  # way, but one Project per repo per run is the population interning exists for.
  class Project
    include Inspectable

    # Where an agent's writes are allowed to land, and what a run reports
    # itself as operating under.
    KINDS = %i[project home].freeze

    # The rungs root/cwd detection climbs, weakest to strongest evidence: an
    # explicit flag, a `.lain/` marker directory, `git`'s own
    # notion of a repo root, or none of the above.
    DETECTED_BY = %i[flag lain_dir git none].freeze

    # `root`/`cwd` failed to resolve to a real path -- missing, or present but
    # unreadable. Names which of the two roles failed and the path given.
    class Unresolvable < Error
      def initialize(role, path, cause)
        super("cannot resolve #{role} #{path.inspect}: #{cause.message}")
      end
    end

    declare do
      attribute :root, :string
      attribute :cwd, :string
      attribute :kind
      attribute :detected_by
      validates :kind, inclusion: { in: KINDS, message: "must be one of #{KINDS.inspect}, got %<value>s" }
      validates :detected_by,
                inclusion: { in: DETECTED_BY, message: "must be one of #{DETECTED_BY.inspect}, got %<value>s" }
      validate :cwd_under_root

      private

      # Both are already REALPATH-resolved here (see #initialize); comparing
      # before resolution would let a symlinked cwd fail a check its resolved
      # self would pass, or the reverse.
      #
      # `File.join(root, "")` rather than `"#{root}/"`: at `root == "/"` the
      # naive interpolation builds `"//"`, which no real cwd starts with, so
      # EVERY cwd under `/` was refused over a relationship that plainly held.
      # `File.join` normalizes the doubled slash away while still anchoring on a
      # real separator, so a same-prefix sibling (`/tmp` vs `/tmp-other`) keeps
      # being refused rather than let through by a bare `start_with?`.
      def cwd_under_root
        return if root.nil? || cwd.nil?
        return if cwd == root || cwd.start_with?(File.join(root, ""))

        errors.add(:cwd, "must lie under root -- root=#{root}, cwd=#{cwd}")
      end
    end

    def to_s = "#{kind}:#{root} cwd=#{cwd} via=#{detected_by}"
  end
end
