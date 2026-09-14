# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): matches a glob pattern against a base directory.
    # Direct Ruby, no subprocess -- the lowest-risk shape, since there is no
    # command string here for the model to control.
    #
    # == No path check here, and where the boundary actually is
    #
    # This tool checks no path, and no sibling tier-1 tool ({ReadFile},
    # {ListFiles}, {EditFile}) confines its `path` either. That is doctrine
    # rather than an omission: {Tool::Input}'s own docs are explicit that its
    # validations check shape, not safety, and a control a tool applies to
    # itself is one every later tool has to remember to copy.
    #
    # The boundary is built, wired and live -- it just sits in three positions
    # outside the tools, judging three different things:
    #
    # 1. GATE ON THE EFFECT, before a tool runs. {Lain::Sensitivity::Policy}
    #    classifies the path an effect names, and two handlers read that one
    #    table: {Middleware::Sensitivity} refuses a DENIED path outright,
    #    where no approval can lift it, and {Middleware::Gate} sends a
    #    GATED one to a human. It cannot be a property a tool declares about
    #    itself -- `read_file` is tier 1 for `README.md` and worth asking about
    #    for `.env`, and the difference is in the argument.
    # 2. FILTER ON THE RESULT, after it runs. {Middleware::WithholdSecretPaths}
    #    drops the sensitive rows out of a `glob`/`grep`/`list_files` listing
    #    and reports how many it dropped. It sifts through the same policy's own
    #    filter, so a listing cannot enumerate what the gate refuses to read --
    #    and this tool is unchanged by it.
    # 3. MASK ON THE CONTENT, once bytes exist. Whether a file's BYTES look like
    #    a credential is a question no path classifier can answer before the
    #    open, so {Middleware::RedactSecretReads} masks the flagged regions
    #    post-read and parks a pending for their release. OS confinement is
    #    the layer under all three.
    #
    # It withholds SENSITIVE paths, never OUTSIDE-ROOT ones. An absolute
    # pattern, or one that climbs out via `../`, is still honored rather than
    # rejected, same as it would be for `read_file` or `list_files`; what a
    # denied path loses is its row in the answer, not the walk that found it.
    class Glob < Tool
      include Tool::FileTarget

      # A glob is an ENUMERATION under {Tool::Bounds}' stated boundary: its
      # rows are independent answers, so the first N ARE a usable partial answer
      # and the model can narrow the pattern itself. It caps and discloses in
      # band rather than refusing.
      #
      # 500 is a BYTE BUDGET rather than a taste. Grep's 200 rows of
      # `path:lineno:text` are ~70 B each, so ~14 KB of observation; a path row
      # measures 33.5 B on average over this repo's 1610 tracked files, so 500
      # is ~17 KB -- the same order, so the two tools' worst cases cost a turn
      # comparably. It sits above every query a human organizes a subtree for
      # while bounding the pathological ones this exists for.
      #
      # The cap is applied to the SORTED list, never by stopping the walk, which
      # is what keeps "deterministic sorted order" true of a capped result --
      # see the walk-order divergence {Grep} records, where two search paths
      # return different 200s of the same tree.
      BOUND = Tool::Bounds::Enumeration.new(limit: 500, unit: "paths")

      # The wire shape: a required glob pattern, plus an optional base
      # directory it is matched from.
      class Input < Tool::Input
        field :pattern, :string, description: "Glob pattern to match, e.g. \"**/*.rb\".", required: true
        field :path, :string,
              description: "Base directory the pattern is matched from. Defaults to the current directory."
      end

      input_model Input

      class << self
        # Public and class-level so {Middleware::WithholdSecretPaths} can
        # recognize this exact sentinel STRUCTURALLY -- rebuilding it from this
        # one definition and comparing -- rather than by matching words inside
        # it, which is what let a no-match result under a gated directory get
        # misread as a withheld path (a real regression).
        def no_matches_message(pattern, base)
          "glob: no matches for #{pattern.inspect} under #{base}"
        end
      end

      def name = "glob"

      def description
        "Finds paths matching a glob pattern (e.g. \"**/*.rb\") relative to " \
          "an optional base directory, returned one per line in sorted " \
          "order. Output is capped at #{BOUND.limit} paths; a capped result " \
          "says so and names the true match count rather than truncating " \
          "silently. No matches is not an error -- the result names the " \
          "pattern and says there were no matches, not an empty string."
      end

      # Audited: reads Session#worker_env.cwd (a value read, not a mutation) to
      # resolve `base`, then only calls Dir.glob. No Session write, no chdir --
      # `Dir.glob`'s `base:` resolves without touching process-global Dir.pwd.
      def parallel_safe? = true

      protected

      def perform(input, invocation)
        # The base resolves against the session's WorkerEnv cwd, which is
        # `Dir.pwd` under the default, so the rows stay base-relative. An
        # absent path IS that cwd -- {Lain::WorkerEnv#resolve}'s nil arm, which
        # this tool used to respell as `input.path || "."`.
        base = target(invocation, input.path)
        found = matches(base, input.pattern)
        Tool::Result.ok(found.empty? ? self.class.no_matches_message(input.pattern, base) : found.join("\n"))
      end

      private

      # {BOUND} is applied after `.sort` and never by stopping the walk: `cap`
      # reads the true count off the collection it is handed, and the surviving
      # rows are decided by the ordering rather than by the filesystem.
      def matches(base, pattern)
        BOUND.cap(Dir.glob(pattern, base:).sort)
      end
    end
  end
end
