# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): runs a search query and returns ranked, titled,
    # linked results. The tool is deliberately CREDENTIAL-AGNOSTIC: it owns no
    # API key and no endpoint. A search backend is injected, and the tool only
    # ranks-and-renders whatever that backend returns -- so choosing (and
    # crendentialing) a concrete provider stays a wiring decision, never baked
    # into this leaf. See the plan's "Web-tool safety": bounded by structure,
    # not an approval gate, so {#requires_approval?} stays false.
    #
    # The backend contract is one message: `call(query)` returning an Enumerable
    # of objects that respond to `#title` and `#url` (and optionally `#snippet`)
    # -- {Result} is the shipped shape. A raising backend becomes an error
    # {Tool::Result}; empty results are an ok Result naming the absence. The
    # default backend is a Null Object so the tool is constructible before any
    # provider is wired -- an unconfigured search simply finds nothing, loudly.
    class WebSearch < Tool
      # One ranked hit. A plain, deeply-frozen value: what a backend yields and
      # what the tool renders.
      Result = Data.define(:title, :url, :snippet) do
        def initialize(title:, url:, snippet: nil)
          super
        end
      end

      # The Null backend: no provider wired, so nothing is found. Named rather
      # than a bare `->{ [] }` so the "unconfigured" state is legible in a
      # rendered result and in a stack trace.
      module Backend
        Null = ->(_query) { [] }
      end

      # The backend is injected (default the Null Object). It is any object
      # responding to `#call(query)`; a lambda is the common shape, a richer
      # object with its own HTTP client is equally valid.
      def initialize(backend: Backend::Null)
        super()
        @backend = backend
      end

      def name = "web_search"

      def description
        "Searches the web for a query and returns ranked results, each with a " \
          "title and a URL. Returns an error result if the search backend fails."
      end

      # The wire shape: one required query string.
      class Input < Tool::Input
        field :query, :string, description: "Search query.", required: true
      end

      input_model Input

      protected

      def perform(input, _invocation)
        results = Array(@backend.call(input.query))
        return Tool::Result.ok("web_search: no results for #{input.query.inspect}") if results.empty?

        Tool::Result.ok(render(results))
      rescue StandardError => e
        Tool::Result.error("web_search failed for #{input.query.inspect}: #{e.message}")
      end

      private

      def render(results)
        results.each_with_index.map { |hit, i| render_hit(hit, i + 1) }.join("\n\n")
      end

      def render_hit(hit, rank)
        lines = ["#{rank}. #{hit.title}", "   #{hit.url}"]
        snippet = hit.respond_to?(:snippet) ? hit.snippet : nil
        lines.push("   #{snippet}") if snippet
        lines.join("\n")
      end
    end
  end
end
