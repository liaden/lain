# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): runs a search query and returns ranked, titled,
    # linked results. Deliberately CREDENTIAL-AGNOSTIC -- it owns no API key and
    # no endpoint -- so choosing and credentialing a provider stays a wiring
    # decision rather than being baked into this leaf. Bounded by structure and
    # not an approval gate, so {#requires_approval?} stays false.
    #
    # The backend contract is one message: `call(query)` returning an Enumerable
    # of objects answering `#title` and `#url`, optionally `#snippet`. The one
    # exception is {Backend::Null}, which returns {Backend::NOT_CONFIGURED} and
    # NOT an Enumerable, so a decorating backend must delegate the call WHOLE
    # rather than compose over it.
    #
    # An unconfigured search says so distinguishably from a configured backend
    # that searched and came up empty, so the model does not keep retrying a
    # search that was never going to work.
    class WebSearch < Tool
      # Ranked hits are an ENUMERATION under {Tool::Bounds}' boundary, and this
      # is the one tool whose ordering this repo does not own. The obvious
      # objection -- "a nondeterministic cap" -- does not apply: the tool
      # imposes no ordering at all, so the survivors are `first(limit)` of
      # exactly what came back in the RANK the backend chose. Two identical
      # responses cap identically, and unlike a filesystem walk order rank is
      # MEANINGFUL, so top-N is the right partial answer.
      #
      # The notice's TOTAL means something narrower here than elsewhere. For the
      # five filesystem tools N is the universe; here it is only what THIS call
      # returned, so a backend that pages internally makes N a page size. True
      # rather than misleading -- N is exactly the number of results the cap
      # withheld rows from -- but a reader who learned the sentence on `glob`
      # would otherwise carry the stronger reading over.
      #
      # 20, and small on purpose: a rendered hit is the fattest row shape of the
      # six at ~250-400 B, so 20 already reach ~6-8 KB. Conventional backends
      # page at 10-20, so this bounds a backend answering with hundreds without
      # touching one that behaves.
      BOUND = Tool::Bounds::Enumeration.new(limit: 20, unit: "results")

      # A snippet is as long as the backend makes it, so the hits also meet a
      # byte ceiling.
      BYTE_BOUND = Tool::Bounds::Fill.new(limit: Tool::Bounds::CEILINGS.fetch("web_search"), unit: "results",
                                          narrower: ["search a narrower query"])

      HIT_SEPARATOR = "\n\n"

      # One ranked hit: what a backend yields and what the tool renders.
      Result = Data.define(:title, :url, :snippet) do
        def initialize(title:, url:, snippet: nil)
          super
        end
      end

      module Backend
        # In place of an empty Array, so {#perform} can tell "no backend wired"
        # apart from "a real backend searched and found nothing" without
        # widening the `#call(query)` duck.
        #
        # {#perform} checks identity with THIS constant as the RECEIVER
        # (`NOT_CONFIGURED.equal?(raw)`), never `raw`, so a backend result that
        # overrides `#equal?` cannot forge a match. Public, so a decorating
        # backend that legitimately claims "unconfigured" can return this exact
        # value rather than only delegating to {Null}.
        NOT_CONFIGURED = Object.new.freeze

        # Named rather than a bare `->{ [] }`, so the "unconfigured" state is
        # legible in a rendered result and in a stack trace.
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
          "title and a URL. Output is capped at the top #{BOUND.limit} " \
          "results; a capped result says so and names the true count rather " \
          "than truncating silently. Returns an error result if the search " \
          "backend fails."
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

      # Names the query, so an interleaved transcript ties this back to its
      # call, and reads as NON-RETRYABLE: a QA run retried an earlier wording
      # six times, because "no search backend is configured" alone reads like a
      # transient condition a different query might dodge.
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

      # A backend has already materialised every hit by the time it returns, so
      # the true count the notice needs is its size, and only the hits the row
      # cap lets through are rendered. The notice rides beside {BYTE_BOUND} as
      # a trailer, so the byte ceiling cannot withhold it.
      def render(results)
        hits = results.first(BOUND.limit).each_with_index.map { |hit, i| render_hit(hit, i + 1) }
        trailers = BOUND.admits?(results.size) ? [] : [BOUND.notice(results.size)]
        [*BYTE_BOUND.fit(hits, beside: trailers, separator: HIT_SEPARATOR), *trailers].join(HIT_SEPARATOR)
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
