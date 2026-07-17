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

      protected

      def perform(input, _invocation)
        Tool::Result.ok(matches(input.path || ".", input.pattern).join("\n"))
      end

      private

      def matches(base, pattern)
        Dir.glob(pattern, base:).sort
      end
    end
  end
end
