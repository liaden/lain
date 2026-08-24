# frozen_string_literal: true

module Lain
  class Provider
    class Ollama < Provider
      # A thin subclass of the vendored HTTP provider base that exposes the one
      # non-streaming round trip {Ollama} needs, REUSING the vendored Faraday
      # stack (timeout, faraday-retry, JSON de/serialization, error mapping, the
      # injected-Sink logger). It deliberately does NOT go through the vendored
      # `complete`/`sync_response`: the payload is already rendered by
      # {Ollama::Encoding}, so the body is posted as-is and handed straight back.
      #
      # Which server, and with whose credential, are both answered PER INSTANCE
      # here, because both are read off a Configuration handed to the
      # constructor. A class predicate cannot describe an object whose endpoint
      # is an argument, so {#local?} delegates to
      # {Provider::Admission::Endpoint.local?} over {#api_base} and {#headers}
      # builds its bearer from `ollama_api_key`.
      #
      # `configuration_requirements` nonetheless stays EMPTY, and that is not an
      # oversight: it is a class-level list `Connection#ensure_configured!`
      # refuses construction over, so requiring the key would refuse every
      # loopback connection -- the default arm, which wants no credential at
      # all. The refusal that names `OLLAMA_API_KEY` belongs to
      # {Deployment::Cloud}, where it is per-deployment.
      #
      # Its `ollama_api_base` and `ollama_api_key` Configuration options are
      # registered at load (below) via
      # `register_provider_options` directly, NOT `Provider::HTTP::Provider.register`:
      # this is a Lain-native provider reusing the transport base, not a member
      # of the vendored slice's slug registry, so it takes the option seam
      # without adding a `resolve(:ollama)` entry the vendored code never looks up.
      class Transport < Provider::HTTP::Provider
        # Rooted at {Lain::Error} so `exe/lain`'s top-level rescue maps it
        # instead of dumping a trace, and so it cannot escape the way the bare
        # `ArgumentError` it replaces did. NOT a {Provider::HTTP::Error}: that
        # family means "the server said no", and nothing was ever sent here.
        class UnusableCredential < Lain::Error; end

        COMPLETION_PATH = "api/chat"
        # The loaded-runner listing. It is the ONLY endpoint that states the
        # window a model is actually being served with -- `/api/show` reports
        # the GGUF's trained maximum, which is a different and larger number.
        # See references/ollama/api-show-and-context.md.
        PROCESS_PATH = "api/ps"
        # The model's own metadata, including the GGUF KV table its TRAINED
        # maximum lives in. Never a served window -- see {PROCESS_PATH} and
        # references/ollama/api-show-and-context.md.
        SHOW_PATH = "api/show"
        DEFAULT_API_BASE = "http://localhost:11434"

        # What an HTTP header field value cannot carry. `[[:cntrl:]]` is the
        # whole class Net::HTTP refuses -- CR, LF, tab, NUL and the rest of
        # \x00-\x1F plus \x7F -- not just the two spellings that motivated the
        # guard; a rule matching only `\r\n` leaves a lone `\r` and a lone `\n`
        # open, and the adapter refuses all three alike.
        #
        # It lives HERE, in the object that puts a value into a header, and
        # {Deployment::Cloud} reads it from here rather than keeping a second
        # copy: "what a header cannot carry" is one fact and belongs in one
        # place, even though the two guards that consult it are not duplicates
        # (see {#headers}).
        UNUSABLE_IN_HEADER = /[[:cntrl:]]/

        # Deliberately says nothing about the value. This is the one string in
        # the process that must never reach a log line, and an exception message
        # is a log line waiting to happen -- quoting the key here would only
        # move the leak out of Net::HTTP's `ArgumentError` and into ours, which
        # is worse, because ours is the one callers are told to rescue and
        # report.
        UNUSABLE_CREDENTIAL = "ollama_api_key contains a line break or control character, which an " \
                              "HTTP header field value cannot carry (a key pasted from a " \
                              "soft-wrapped page, or read from a CRLF file, carries one " \
                              "invisibly). Its value is withheld here because it is a live credential"

        # A metadata probe is not a completion and must not inherit a
        # completion's patience. `/api/ps` answers in ~0.3ms when ollama is up;
        # when it is DOWN -- the ordinary state of this arm, which is also the
        # default summarizer -- `Faraday::ConnectionFailed` and `ServerError`
        # are both in {Connection::MiddlewareStack#retry_exceptions}, so the
        # completion budget spends four attempts and ~790ms (measured against a
        # dead port, 2026-08-17; this budget makes the same case 0.3ms) before
        # giving up. That is dead wall time on the render path, for a
        # number every caller already has a fallback for. One attempt, and a
        # timeout two orders of magnitude under the completion path's 300s: a
        # probe that cannot answer promptly has answered.
        PROBE_TIMEOUT_SECONDS = 2

        # One non-streaming round trip. `faraday.response :json` has already
        # parsed the body, so `#body` is a Hash.
        #
        # `attempt` is the round trip's own {RetryTap::Attempt}, put on the
        # Faraday request context so {RetryTap#retry_block} reaches THIS
        # request's attempt off the retried env rather than instance state --
        # the transport stays retry-blind and never learns what abandoning one
        # means. It defaults to an attempt with nothing to discard, so a caller
        # with no tap (the embedder, a spec) is unaffected.
        def sync_post(payload, headers = {}, attempt: RetryTap::Attempt.new)
          connection.post(COMPLETION_PATH, payload) do |req|
            req.headers = headers.merge(req.headers) unless headers.empty?
            req.options.context = (req.options.context || {}).merge(retry_attempt: attempt)
          end
        end

        # One streaming round trip. Raw byte chunks (any TCP boundary) are yielded
        # to `on_chunk`; {StreamAssembler} owns the NDJSON line reassembly. Only
        # the vendored `on_data` byte-feeding is reused here, NOT the SSE engine
        # (`build_on_data_handler`), which folds every chunk through
        # `EventStreamParser` -- meaningless for `application/x-ndjson`.
        #
        # A non-2xx raises the SAME typed error, with the same status and the
        # same sentence, the non-streaming path raises -- which takes one rescue,
        # because the middleware that raises it sits INSIDE this call and by then
        # the body it would quote has already streamed past into
        # {StreamedFailure}. See that class for what the body loss costs a human.
        def stream(payload, headers = {}, attempt: RetryTap::Attempt.new, &on_chunk)
          failure = StreamedFailure.new(self)
          connection.post(COMPLETION_PATH, payload) do |req|
            req.headers = headers.merge(req.headers) unless headers.empty?
            # On the context so RetryTap#retry_block reaches THIS request's
            # attempt off the retried env, exactly as #sync_post does.
            req.options.context = (req.options.context || {}).merge(retry_attempt: attempt)
            install_on_data(req, failure, &on_chunk)
          end
        rescue Provider::HTTP::Error => e
          failure.reraise(e)
        end

        # The models currently resident, each with the context length its runner
        # was loaded with. A GET, so it takes no payload; auth is not its
        # business either way, since {Connection} merges {#headers} into every
        # request it makes on this transport's behalf, probe connection
        # included.
        def process_status
          probe_connection.get(PROCESS_PATH)
        end

        # One model's metadata. A POST, because `/api/show` takes the model in
        # a body rather than a path segment (`api/types.go`'s ShowRequest).
        #
        # {#probe_connection}, not {#connection}: this runs at LAUNCH, in front
        # of the chronicle open, and the reference's own advice for a second
        # metadata endpoint is to share the probe's budget rather than spend
        # the completion path's four attempts on a number the caller degrades
        # without.
        def model_details(model)
          probe_connection.post(SHOW_PATH, { model: })
        end

        # The SAME vendored stack the completion path uses -- same middleware,
        # same JSON handling, same error mapping, same injected Sink -- rebuilt
        # from a config that differs only in patience ({PROBE_TIMEOUT_SECONDS}
        # above). This is not the second Faraday the design forbids: that
        # prohibition is against a parallel, hand-rolled HTTP client whose error
        # mapping would drift from this one's. It is {Connection::MiddlewareStack}
        # again, with the retry and timeout numbers a probe should have instead
        # of the ones a completion should. Built lazily, so a provider that never
        # asks for a window never opens it.
        def probe_connection
          @probe_connection ||= Provider::HTTP::Connection.new(self, probe_config, sink: @sink)
        end

        def api_base
          @config.ollama_api_base || DEFAULT_API_BASE
        end

        # Auth in the vendored idiom (`Provider::HTTP::Providers::Bedrock:28-33`):
        # built from Configuration, because Configuration is the only thing the
        # wire path can reach. `Connection#provider_headers` asks THIS object and
        # merges the result into every request, so this is the sole live auth
        # path; a {Deployment}'s own `#headers` is a declaration checked against
        # it by a spec, and is merged nowhere.
        #
        # An absent key answers with no header rather than an empty bearer.
        # Whether a key is any GOOD is deliberately not asked here, because
        # asking would be a SECOND definition of "there is a key" and two of
        # those is how they drift. Two guards already stand in front:
        #
        # 1. {Deployment::Cloud} refuses a nil, non-String, whitespace-only or
        #    control-character key BY NAME, naming `OLLAMA_API_KEY`. That is
        #    the door every shipped caller comes through.
        # 2. On the bypass path -- a Configuration built directly, no
        #    deployment in it -- `Configuration`'s generated setter
        #    (`http/configuration.rb:38-41`) coerces a blank String to nil, so
        #    `"   "` arrives here already absent.
        #
        # Guard 2 special-cases `String` and nothing else, so a non-String key
        # set directly still reaches the wire as `Bearer 12345` (verified). It
        # is a backstop, not a validator; {Deployment::Cloud} is the validator.
        def headers
          key = @config.ollama_api_key
          key.nil? ? {} : { "Authorization" => "Bearer #{wire_safe(key)}" }
        end

        # Delegated, not re-derived, so the gate that decides this transport's
        # concurrency and the transport describing itself cannot disagree --
        # {Provider::Admission::Endpoint.local?} is the codebase's one
        # definition of local, and it already folds every loopback spelling.
        def local? = Provider::Admission::Endpoint.local?(api_base)

        # The base pair delegate to the CLASS, and overriding only half of it
        # would leave a loopback transport answering `local?` true and `remote?`
        # true at the same time.
        def remote? = !local?

        private

        # TWO GUARDS, AND THEY ARE NOT DUPLICATES. They answer different
        # questions, owned in different places, known at different times -- the
        # same shape as the secret boundary's gate/filter/mask split:
        #
        # - POLICY -- "is this a credential a human plausibly meant to set?"
        #   Owned by {Deployment::Cloud}, which refuses nil, non-String,
        #   whitespace-only and unusable keys BY NAME, naming `OLLAMA_API_KEY`
        #   and pointing at the settings page. That is the door every shipped
        #   caller comes through.
        # - WIRE FORMAT -- "may this value go into an HTTP header at all?" Owned
        #   HERE, because this is the object that puts it there, and CR/LF being
        #   illegal in a field value is a fact about HTTP rather than about
        #   Ollama.
        #
        # The wire guard is what stands on the BYPASS path, where a
        # Configuration is built directly and no deployment is involved --
        # `Embedder::Ollama.new(config:)` is the reachable one. There Net::HTTP
        # raised a bare `ArgumentError`, outside {Lain::Error} and so outside
        # every rescue in the codebase, with the live key quoted in its message.
        # Deleting either guard reopens a case the other never covered.
        #
        # A NON-STRING KEY IS DELIBERATELY NOT REFUSED HERE. `Bearer 12345` is a
        # perfectly legal header value, so it is not a wire-format fault; it is
        # a policy fault, and importing that judgement into this method is
        # exactly the second policy validator that must not exist.
        # {Deployment::Cloud} refuses it by name, and a Configuration written
        # directly with an Integer is the caller's own bypass.
        def wire_safe(key)
          raise UnusableCredential, UNUSABLE_CREDENTIAL if key.to_s.match?(UNUSABLE_IN_HEADER)

          key
        end

        # `dup` rather than a fresh Configuration, so an operator's `api_base`,
        # proxy and adapter still reach the probe; only the two budget numbers
        # are overwritten.
        def probe_config
          @config.dup.tap do |config|
            config.max_retries = 0
            config.request_timeout = PROBE_TIMEOUT_SECONDS
          end
        end

        # Reuses the vendored FaradayHandlers' `on_data` proc, feeding raw
        # chunks straight to the NDJSON assembler. `assign_on_data` resolves
        # through the mixed-in `Streaming` engine on the provider base -- this
        # class has no override of its own.
        #
        # The failed arm deliberately does NOT call the vendored
        # `handle_failed_response`, which raises from inside this callback off a
        # status its `parse_streaming_error` GUESSES (500, or 529). The guess is
        # for an in-stream SSE `event: error`, where the response really did
        # return 200 -- but here the true status arrived in the headers before
        # any body byte, and a guessed 500 is in the retry allowlist
        # ({Connection::MiddlewareStack#retry_exceptions}), so a 404 was retried
        # and then answered with the wrong status. That is RES1, which
        # {Provider::Anthropic::Transport} fixes by overriding the guess; on a
        # response already known to have FAILED there is nothing to raise from
        # in here at all, so this arm only accumulates and the one raise happens
        # in #stream, where the real status is what maps it.
        def install_on_data(req, failure, &on_chunk)
          handler = Provider::HTTP::Streaming::FaradayHandlers.build(
            on_chunk: ->(chunk, _env) { yield(chunk) },
            on_failed_response: ->(chunk, _env) { failure.feed(chunk) }
          )
          assign_on_data(req, handler)
        end

        class << self
          # `ollama_api_key` is declared here and NOT in
          # `configuration_requirements` -- see the class docstring for why
          # requiring it would refuse the loopback arm.
          def configuration_options = %i[ollama_api_base ollama_api_key]
        end
      end
    end
  end
end

Lain::Provider::HTTP::Configuration.register_provider_options(
  Lain::Provider::Ollama::Transport.configuration_options
)
