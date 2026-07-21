# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): matches a glob pattern against a base directory.
    # Direct Ruby, no subprocess -- same lowest-risk shape as {ListFiles},
    # which already leans on `Dir.glob` internally for its own recursive
    # listing.
    #
    # No confinement to a project root is enforced here, deliberately: no
    # sibling tier-1 tool ({ReadFile}, {ListFiles}, {EditFile}) confines its
    # `path` either, and {Tool::Input}'s own docs are explicit that these
    # validations check shape, not safety -- the real boundary is the tier
    # system, {Effect::Handler::Gate}, and eventual OS confinement, never a
    # path check inside a tier-1 tool. An absolute pattern, or one that
    # climbs out via `../`, is therefore honored rather than rejected, same
    # as it would be for `read_file` or `list_files`.
    class Glob < Tool
      # The wire shape: a required glob pattern, plus an optional base
      # directory it is matched from.
      class Input < Tool::Input
        field :pattern, :string, description: "Glob pattern to match, e.g. \"**/*.rb\".", required: true
        field :path, :string,
              description: "Base directory the pattern is matched from. Defaults to the current directory."
      end

      input_model Input

      def name = "glob"

      def description
        "Finds paths matching a glob pattern (e.g. \"**/*.rb\") relative to " \
          "an optional base directory, returned one per line in sorted " \
          "order. No matches is not an error -- the result is simply empty."
      end

      # Audited: reads Session#worker_env.cwd (a value read, not a mutation)
      # to resolve `base`, then only calls Dir.glob. No Session write, no
      # chdir -- Dir.glob's `base:` kwarg resolves without touching
      # process-global Dir.pwd.
      def parallel_safe? = true

      protected

      def perform(input, invocation)
        # The base resolves against the session's WorkerEnv cwd -- `Dir.pwd`
        # under the default, so `Dir.glob(base: Dir.pwd)` returns the same
        # base-relative paths as the pre-WorkerEnv `base: "."` did.
        base = File.expand_path(input.path || ".", session_of(invocation).worker_env.cwd)
        Tool::Result.ok(matches(base, input.pattern).join("\n"))
      end

      private

      def matches(base, pattern)
        Dir.glob(pattern, base:).sort
      end
    end
  end
end
