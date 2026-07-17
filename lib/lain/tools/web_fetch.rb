# frozen_string_literal: true

require "faraday"
require "uri"

module Lain
  module Tools
    # Tier 1 (structured): fetches one URL and returns its body text. There is
    # no command string here for the model to control, so it sits at the lowest
    # tier -- but a network egress tool needs bounds a filesystem read does not,
    # and those bounds are STRUCTURAL, not an approval prompt (see the plan's
    # "Web-tool safety"): the body is STREAMED and the read is aborted once it
    # exceeds an egress byte-cap (a lying or absent Content-Length cannot defeat
    # it), redirects are capped, only http/https egress is allowed, NO auth
    # headers are ever sent, and an optional domain allowlist is re-checked on
    # every hop. {#requires_approval?} stays false -- a subagent that owns this
    # tool gets no Gate, so a `true` here would be a no-op, and the real safety
    # is the structure, not a gate.
    #
    # Every failure -- a non-2xx status, too many redirects, a disallowed host
    # or scheme, a malformed redirect Location, a raising client -- is reported
    # as an error {Tool::Result}, never a raise: the loop must continue and the
    # model deserves an answer it can act on. The fetched page is returned as
    # content; it is NEVER written to stdout.
    class WebFetch < Tool
      # 5 MiB is a generous ceiling on a single egress: enough for any real
      # article, small enough to bound a runaway or hostile response.
      DEFAULT_BYTE_CAP = 5 * 1024 * 1024
      # Five hops covers legitimate canonicalization (http->https, trailing
      # slash, apex->www) without letting a redirect loop run unbounded.
      DEFAULT_REDIRECT_CAP = 5
      # Egress is confined to the web: a redirect to file://, gopher://, or a
      # data: URI is refused before the connection is ever asked to fetch it.
      ALLOWED_SCHEMES = %w[http https].freeze
      USER_AGENT = "lain-web-fetch/1"

      # The wire shape: one required URL. Shape only -- Tool::Input never
      # validates safety (see the comment atop tool/input.rb); the scheme guard,
      # allowlist, and caps below are the real bounds, and they live on the tool.
      class Input < Tool::Input
        field :url, :string, description: "Absolute http(s) URL to fetch.", required: true
      end

      input_model Input

      # A streaming sink for Faraday's `on_data`: it accumulates body bytes and
      # ABORTS the read (by raising, the only way Faraday stops a stream) the
      # moment the total would exceed the cap. So the cap bounds the actual read,
      # not just a post-hoc truncation of an already-buffered body.
      class ByteCap
        class Reached < StandardError
        end

        attr_reader :status

        def initialize(cap)
          @cap = cap
          @bytes = +""
          @truncated = false
          @status = nil
        end

        # Faraday 2 hands `(chunk, received_bytes, env)`; earlier arities pass
        # fewer, so the tail is defaulted. `env.status` (when present) is the
        # only status we will have if the read is aborted mid-body.
        def call(chunk, _received = nil, env = nil)
          @status = env.status if env.respond_to?(:status)
          room = @cap - @bytes.bytesize
          accept(chunk, room)
        end

        def truncated? = @truncated

        # A fresh copy so the accumulated buffer cannot be mutated after the fact.
        def bytes = @bytes.dup

        private

        def accept(chunk, room)
          if chunk.bytesize <= room
            @bytes << chunk
          else
            @bytes << chunk.byteslice(0, room)
            @truncated = true
            raise Reached
          end
        end
      end

      # The HTTP client is injected (default a real, credential-free Faraday
      # connection) so specs substitute a stub and never touch the network. The
      # caps and allowlist are constructor config, not model input: the model
      # must not be able to widen its own bounds.
      def initialize(connection: nil, byte_cap: DEFAULT_BYTE_CAP, redirect_cap: DEFAULT_REDIRECT_CAP, allowlist: nil)
        super()
        @connection = connection || default_connection
        @byte_cap = byte_cap
        @redirect_cap = redirect_cap
        @allowlist = allowlist
      end

      def name = "web_fetch"

      def description
        "Fetches a single http(s) URL and returns its body text. The response " \
          "is streamed and capped in size, redirects are bounded, and a non-2xx " \
          "status or a network error is returned as an error result."
      end

      # A bare Faraday connection carrying only a User-Agent -- and, pointedly,
      # NO Authorization, Cookie, or other credential header, and no redirect
      # middleware (redirects are followed here, so each hop can be re-checked).
      # Exposed so the no-auth invariant is directly assertable.
      def default_connection
        Faraday.new(headers: { "User-Agent" => USER_AGENT })
      end

      protected

      def perform(input, _invocation)
        follow(input.url, @redirect_cap)
      rescue Faraday::Error => e
        Tool::Result.error("web_fetch failed for #{input.url}: #{e.message}")
      end

      private

      # One hop. The egress guard (scheme + allowlist) runs BEFORE the fetch, so
      # a disallowed host or scheme is never contacted -- and because a redirect
      # recurses through here, that guard is re-applied to every hop.
      def follow(url, budget)
        problem = egress_problem(url)
        return Tool::Result.error(problem) if problem

        status, headers, body = fetch(url)
        return redirect(url, headers, budget) if redirect?(status, headers)
        return Tool::Result.error("web_fetch: #{status} for #{url}") unless success?(status)

        Tool::Result.ok(body)
      end

      def redirect(from, headers, budget)
        if budget.zero?
          return Tool::Result.error("web_fetch: too many redirects (cap #{@redirect_cap}) starting at #{from}")
        end

        follow(URI.join(from, location_of(headers)).to_s, budget - 1)
      rescue URI::InvalidURIError => e
        Tool::Result.error("web_fetch: malformed redirect Location #{location_of(headers).inspect}: #{e.message}")
      end

      # Streams the body through the byte cap. On a normal completion the
      # response carries status/headers; on an aborted read (cap reached) only
      # the cap's captured status is available -- and that only happens on a
      # large body, never on an empty-bodied redirect, so no header is needed.
      def fetch(url)
        cap = ByteCap.new(@byte_cap)
        response = @connection.get(url) { |req| req.options.on_data = stream_into(cap) }
        [response.status, response.headers || {}, rendered(cap)]
      rescue ByteCap::Reached
        [cap.status || 200, {}, rendered(cap)]
      end

      def stream_into(cap)
        proc { |chunk, received, env| cap.call(chunk, received, env) }
      end

      def rendered(cap)
        return cap.bytes unless cap.truncated?

        "#{cap.bytes}\n\n[web_fetch: truncated at #{@byte_cap} bytes]"
      end

      def redirect?(status, headers)
        (300..399).cover?(status) && !location_of(headers).nil?
      end

      def location_of(headers)
        headers["location"] || headers["Location"]
      end

      def success?(status)
        (200..299).cover?(status)
      end

      # The combined egress guard: an unsupported scheme or a host off the
      # allowlist is a named refusal; nil means "go ahead". A URL we cannot even
      # parse is refused rather than handed to the connection.
      def egress_problem(url)
        uri = URI.parse(url)
        return "web_fetch: unsupported scheme #{uri.scheme.inspect} (only http/https)" unless allowed_scheme?(uri)

        allowlist_problem(uri.host)
      rescue URI::InvalidURIError => e
        "web_fetch: invalid url #{url.inspect}: #{e.message}"
      end

      def allowed_scheme?(uri)
        ALLOWED_SCHEMES.include?(uri.scheme)
      end

      # nil allowlist means "no restriction". A configured allowlist matches the
      # host exactly or as a parent domain (example.com allows www.example.com).
      def allowlist_problem(host)
        return nil if @allowlist.nil?
        return nil if host && @allowlist.any? { |domain| host == domain || host.end_with?(".#{domain}") }

        "web_fetch: host #{host.inspect} is not on the allowlist"
      end
    end
  end
end
