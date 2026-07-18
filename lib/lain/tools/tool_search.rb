# frozen_string_literal: true

module Lain
  module Tools
    # The on-demand half of the {Toolset::Disclosure::Deferred} arm (T13):
    # given a query, either returns one tool's full input schema (an exact
    # name match) or a list of matching catalog entries (name + one-line
    # description) -- the same shape {Toolset::Disclosure::Deferred} renders
    # upfront.
    #
    # == Possession gates disclosure, not just invocation
    #
    # This is the security-relevant half of the seam. `toolset:` is injected
    # -- the EXACT (possibly attenuated) {Lain::Toolset} this tool instance
    # belongs to -- and every lookup, exact or fuzzy, walks that Toolset and
    # nothing else. A tool dropped via `#only`/`#except` before this instance
    # was built is not a candidate at any point: it is never in `toolset`'s
    # `#each`, so no query -- however it is phrased -- can surface its
    # schema or even its name. Searching does not grant capability; it can
    # only ever describe capability already held. See {Lain::Toolset}'s own
    # comment: attenuation is the security primitive precisely because a
    # dropped tool cannot be regained by the holder, and a search tool that
    # consulted anything wider than its own Toolset would silently defeat
    # that.
    #
    # `toolset:` follows the same thunk convention {AskHuman} uses for
    # `parent:`: a Toolset or a `-> { toolset }`, since this tool is itself a
    # member of the Toolset it searches -- the toolset must exist before it
    # can be constructed with this tool in it, so the reference is late-bound.
    class ToolSearch < Tool
      # The wire shape: a single free-form query, doing double duty as an
      # exact tool name (schema lookup) or a search term (catalog lookup).
      class Input < Tool::Input
        field :query, :string, required: true,
                               description: "A tool name or a search term. An exact name match " \
                                            "returns that tool's full input schema; otherwise " \
                                            "matches are searched for in tool names and " \
                                            "descriptions and returned as a catalog (name plus " \
                                            "one-line description, no schema)."
      end

      input_model Input

      def name = "tool_search"

      def description
        "Searches the tool catalog for the CURRENT toolset -- the tools this " \
          "agent actually holds, nothing more. Pass a tool's exact name to get " \
          "its full input schema; pass any other text to search tool names and " \
          "descriptions and get back matching catalog entries. Use this " \
          "before calling a tool that was only listed by name and one-line " \
          "description upfront (deferred disclosure)."
      end

      def initialize(toolset:)
        super()
        @toolset = toolset
      end

      protected

      def perform(input, _invocation)
        query = input.query
        return Tool::Result.ok(schema_for(query)) if toolset.include?(query)

        Tool::Result.ok(render(search(query), query))
      end

      private

      def schema_for(query)
        Canonical.dump(toolset.fetch(query).to_schema)
      end

      # Case-insensitive substring match over name and {Tool#one_line_description}
      # -- NOT the fuller `#description` -- so a match can never exist for text
      # this method is not also willing to render in {#render}. Matching and
      # rendering sharing one projection is what makes "search never discloses
      # more than the catalog would" structural rather than two truncation
      # rules that could drift; see {Tool#one_line_description}'s comment.
      def search(query)
        needle = query.downcase
        toolset.select do |candidate|
          candidate.name.downcase.include?(needle) || candidate.one_line_description.downcase.include?(needle)
        end
      end

      def render(matches, query)
        return "no tools match #{query.inspect}" if matches.empty?

        matches.map { |candidate| "#{candidate.name}: #{candidate.one_line_description}" }.join("\n")
      end

      # The live Toolset this instance searches: a Toolset passes through, a
      # thunk (`-> { toolset }`) is called -- late-bound because this tool is
      # itself a member of the Toolset it searches (see the class comment).
      def toolset
        @toolset.respond_to?(:call) ? @toolset.call : @toolset
      end
    end
  end
end
