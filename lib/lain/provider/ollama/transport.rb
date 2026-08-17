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
      # Unlike {Provider::HTTP::Providers::Anthropic} this is a LOCAL provider --
      # no api key, no auth header, no configuration requirement -- so `local?`
      # is true and `configuration_requirements` stays empty. Its
      # `ollama_api_base` Configuration option is registered at load (below) via
      # `register_provider_options` directly, NOT `Provider::HTTP::Provider.register`:
      # this is a Lain-native provider reusing the transport base, not a member
      # of the vendored slice's slug registry, so it takes the option seam
      # without adding a `resolve(:ollama)` entry the vendored code never looks up.
      class Transport < Provider::HTTP::Provider
        COMPLETION_PATH = "api/chat"
        # The loaded-runner listing. It is the ONLY endpoint that states the
        # window a model is actually being served with -- `/api/show` reports
        # the GGUF's trained maximum, which is a different and larger number.
        # See references/ollama/api-show-and-context.md.
        PROCESS_PATH = "api/ps"
        DEFAULT_API_BASE = "http://localhost:11434"

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
        # was loaded with. A GET, so it takes no payload and no headers -- Ollama
        # is local and this transport sends no auth.
        def process_status
          probe_connection.get(PROCESS_PATH)
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

        private

        # `dup` rather than a fresh Configuration, so an operator's `api_base`,
        # proxy and adapter still reach the probe; only the two budget numbers
        # are overwritten.
        def probe_config
          @config.dup.tap do |config|
            config.max_retries = 0
            config.request_timeout = PROBE_TIMEOUT_SECONDS
          end
        end

        # Reuses the version-correct `on_data` proc (Faraday 1 vs 2 arity differ)
        # from the vendored FaradayHandlers, feeding raw chunks straight to the
        # NDJSON assembler. `faraday_1?` resolves through the mixed-in `Streaming`
        # engine on the provider base.
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
            faraday_v1: faraday_1?,
            on_chunk: ->(chunk, _env) { yield(chunk) },
            on_failed_response: ->(chunk, _env) { failure.feed(chunk) }
          )
          assign_on_data(req, handler)
        end

        # Faraday 1 takes `on_data` as a Hash key, Faraday 2 as an accessor.
        def assign_on_data(req, handler)
          if faraday_1?
            req.options[:on_data] = handler
          else
            req.options.on_data = handler
          end
        end

        class << self
          def configuration_options = %i[ollama_api_base]

          def local? = true
        end
      end
    end
  end
end

Lain::Provider::HTTP::Configuration.register_provider_options(
  Lain::Provider::Ollama::Transport.configuration_options
)
