# frozen_string_literal: true

module Lain
  Project = Data.define(:root, :cwd, :kind, :detected_by) do
    include Guardable

    # `File.realpath` resolves symlinks AND requires the path to exist,
    # deliberately: a Project names a real place on disk, and letting a
    # missing/dangling path raise here -- loudly -- is preferable to guessing
    # at a lexical fallback that would silently change what "cwd is under
    # root" means (see `Paths#resolved`'s fallback, which is NOT copied here).
    #
    # `File.realpath` can also raise on a path that DOES exist (EACCES on an
    # unreadable ancestor, e.g. `/proc/1/root` under a normal user), so the
    # raw `SystemCallError` is caught here and renamed to `Unresolvable`
    # rather than left to escape as an unnamed exception -- the same failure
    # {Epic::Home::UnreadableHome}'s own comment describes ("a raw
    # `Errno::EISDIR` escapes exe/lain's `rescue Lain::Error` and prints a
    # backtrace at a user who asked for a status report"). Resolved
    # separately, exactly like {Review::Source::LocalBranch}'s base/head
    # split, so a refusal can name WHICH role failed rather than merely that
    # one did.
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
  # keyword or bare constant written INSIDE that block is scoped to its
  # lexical position -- this file, i.e. `Lain` -- not to the Data-defined
  # class (CLAUDE.md, Known traps; {Review::Anchor} is the precedent).
  #
  # Sent, not stored -- {Workspace} and {WorkerEnv}'s own shape: a Project
  # rides a run's Session/Context, never the Timeline, so which project a turn
  # ran under never enters a digest.
  #
  # `detected_by` is not decoration for a log line: it is the rung root/cwd
  # detection (a later chunk) climbed to find this Project, and later work
  # (this project's own consent rule) branches on it directly.
  #
  # `guard do ... end` lives HERE, below {KINDS}/{DETECTED_BY}, rather than in
  # the `Data.define` block above -- the same reason {Improvement}'s own guard
  # reaches those constants by BARE name rather than through a lambda: this
  # block's lexical nesting is `[Project, Lain]`, so `KINDS` resolves directly
  # once construction actually validates, with nothing to defer.
  class Project
    include Inspectable

    # Where an agent's writes are allowed to land, and what a run reports
    # itself as operating under.
    KINDS = %i[project home].freeze

    # The rungs root/cwd detection climbs, weakest to strongest evidence: an
    # explicit flag, a config file, a `.lain/` marker directory, `git`'s own
    # notion of a repo root, or none of the above.
    DETECTED_BY = %i[flag config lain_dir git none].freeze

    # `root`/`cwd` failed to resolve to a real path -- missing, or present but
    # unreadable. Names which of the two roles failed (see #initialize) and
    # the path that was given, the way {Epic::Home::UnreadableHome} names its
    # container.
    class Unresolvable < Error
      def initialize(role, path, cause)
        super("cannot resolve #{role} #{path.inspect}: #{cause.message}")
      end
    end

    guard do
      attribute :root, :string
      attribute :cwd, :string
      attribute :kind
      attribute :detected_by
      validates :kind, inclusion: { in: KINDS, message: "must be one of #{KINDS.inspect}, got %<value>s" }
      validates :detected_by,
                inclusion: { in: DETECTED_BY, message: "must be one of #{DETECTED_BY.inspect}, got %<value>s" }
      validate :cwd_under_root

      private

      # `root` and `cwd` are already the REALPATH-resolved forms by the time
      # this runs (see #initialize) -- comparing before resolution would let a
      # symlinked cwd fail a check its resolved self would pass, or the
      # reverse.
      #
      # `File.join(root, "")` rather than `"#{root}/"`: at `root == "/"` the
      # naive interpolation builds `"//"`, which no real cwd starts with, so
      # EVERY cwd under `/` failed this check with a refusal that named a
      # relationship that plainly held. `File.join` normalizes the doubled
      # slash away (`join("/", "") == "/"`) while still anchoring on a real
      # path separator, so a same-prefix sibling (`/tmp` vs `/tmp-other`)
      # keeps being refused rather than let through by a bare `start_with?`.
      def cwd_under_root
        return if root.nil? || cwd.nil?
        return if cwd == root || cwd.start_with?(File.join(root, ""))

        errors.add(:cwd, "must lie under root -- root=#{root}, cwd=#{cwd}")
      end
    end

    def to_s = "#{kind}:#{root} cwd=#{cwd} via=#{detected_by}"
  end
end
