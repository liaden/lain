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
    # -- {Result} is the shipped shape. The one exception is {Backend::Null},
    # which returns {Backend::NOT_CONFIGURED} instead -- not an Enumerable -- so
    # a decorating backend that composes over `Null.call(q)` (`.map`, `.select`,
    # ...) will raise; delegate the call whole rather than compose over it. A
    # raising backend becomes an error {Tool::Result}; empty results are an ok
    # Result naming the absence. The default backend is a Null Object so the
    # tool is constructible before any provider is wired -- and an unconfigured
    # search says so, distinguishably from a configured backend that searched
    # and came up empty, so the model does not keep retrying a search that was
    # never going to work.
    class WebSearch < Tool
      # One ranked hit. A plain, deeply-frozen value: what a backend yields and
      # what the tool renders.
      Result = Data.define(:title, :url, :snippet) do
        def initialize(title:, url:, snippet: nil)
          super
        end
      end

      module Backend
        # Returned by {Null} in place of an empty Array, so {#perform} can tell
        # "no backend wired" apart from "a real backend searched and found
        # nothing" -- without widening the `#call(query)` duck with a second
        # method. A frozen, unique object: the only Enumerable shapes an
        # ordinary backend returns are an empty result set or a set of hits,
        # never this exact object, so nothing but {Null} itself can produce it
        # -- and {#perform} checks identity with THIS constant as the receiver
        # (`NOT_CONFIGURED.equal?(raw)`), never `raw`, so a backend result that
        # overrides `#equal?` cannot forge a match. Public, like
        # `Agent::Collaborators::OMITTED`: a decorating backend that legitimately
        # wants to claim "unconfigured" needs to be able to return this exact
        # value, not just delegate to {Null}.
        NOT_CONFIGURED = Object.new.freeze

        # The Null backend: no provider wired. Named rather than a bare
        # `->{ [] }` so the "unconfigured" state is legible in a rendered
        # result and in a stack trace.
        Null = ->(_query) { NOT_CONFIGURED }
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
        raw = @backend.call(input.query)
        return Tool::Result.ok(not_configured_message(input.query)) if Backend::NOT_CONFIGURED.equal?(raw)

        results = Array(raw)
        return Tool::Result.ok(no_results_message(input.query)) if results.empty?

        Tool::Result.ok(render(results))
      rescue StandardError => e
        Tool::Result.error(search_failed_message(input.query, e))
      end

      private

      # Names the query (so an interleaved transcript can tie this result back
      # to its call) and reads as non-retryable: the QA run this card exists to
      # fix retried a version of this message six times because "no search
      # backend is configured" alone reads like a transient condition a
      # different query might dodge.
      def not_configured_message(query)
        "web_search: no search backend is configured for #{query.inspect}; " \
          "searching is unavailable this session -- use another source instead of retrying."
      end

      def no_results_message(query)
        "web_search: no results for #{query.inspect}"
      end

      def search_failed_message(query, error)
        "web_search failed for #{query.inspect}: #{error.message}"
      end

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
