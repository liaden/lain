# frozen_string_literal: true

module Lain
  class Provider
    class Ollama < Provider
      # A thin subclass of the vendored HTTP provider base, REUSING its Faraday
      # stack (timeout, faraday-retry, JSON handling, error mapping, the
      # injected-Sink logger). It deliberately does NOT go through the vendored
      # `complete`/`sync_response`: the payload is already rendered by
      # {Ollama::Encoding}, so the body is posted as-is and handed straight back.
      #
      # Which server, and with whose credential, are answered PER INSTANCE off
      # the Configuration handed to the constructor -- a class predicate cannot
      # describe an object whose endpoint is an argument.
      #
      # `configuration_requirements` nonetheless stays EMPTY: it is a
      # class-level list `Connection#ensure_configured!` refuses construction
      # over, so requiring the key would refuse every loopback connection. The
      # refusal that names `OLLAMA_API_KEY` belongs to {Deployment},
      # where it is per-deployment.
      #
      # The Configuration options are registered below through
      # `register_provider_options` directly, NOT
      # `Provider::HTTP::Provider.register`: this is a Lain-native provider
      # reusing the transport base rather than a member of the vendored slice's
      # slug registry, so it takes the option seam without adding a
      # `resolve(:ollama)` entry the vendored code never looks up.
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
        # guard: a rule matching only `\r\n` leaves a lone `\r` and a lone `\n`
        # open, and the adapter refuses all three alike.
        #
        # It lives HERE, in the object that puts a value into a header, and
        # {Deployment} reads it from here rather than keeping a copy.
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
        # completion's patience. When ollama is DOWN -- the ordinary state of
        # this arm, which is also the default summarizer -- the completion
        # budget spends four attempts and ~790ms before giving up (measured
        # against a dead port; this budget makes the same case 0.3ms). That is
        # dead wall time on the render path, for a number every caller already
        # has a fallback for. A probe that cannot answer promptly has answered.
        PROBE_TIMEOUT_SECONDS = 2

        # One non-streaming round trip. `faraday.response :json` has already
        # parsed the body, so `#body` is a Hash.
        #
        # `attempt` and `frame` ride the Faraday request CONTEXT so
        # {RetryTap#retry_block} reaches THIS request's pair off the retried env
        # rather than instance state -- the transport stays retry-blind. The
        # bytes are not copied here: the shared
        # {Provider::Anthropic::WalResponseTee} sits below `response :json` and
        # captures `env.body` while it is still the wire string. This method's
        # own job is to open the context slot and to TERMINATE the frame.
        def sync_post(payload, headers = {}, attempt: RetryTap::Attempt.new, frame: Spool::Null::Frame.new)
          terminating(frame) do
            connection.post(COMPLETION_PATH, payload) do |req|
              req.headers = headers.merge(req.headers) unless headers.empty?
              req.options.context = (req.options.context || {}).merge(retry_attempt: attempt, wal_frame: frame)
            end
          end
        end

        # One streaming round trip. Raw byte chunks (any TCP boundary) are yielded
        # to `on_chunk`; {StreamAssembler} owns the NDJSON line reassembly. Only
        # the vendored `on_data` byte-feeding is reused here, NOT the SSE engine
        # (`build_on_data_handler`), which folds every chunk through
        # `EventStreamParser` -- meaningless for `application/x-ndjson`.
        #
        # A non-2xx raises the SAME typed error the non-streaming path raises,
        # which takes one rescue: the middleware that raises it sits INSIDE this
        # call, and by then the body it would quote has already streamed past
        # into {StreamedFailure}. Unlike the sync path this one tees its OWN
        # bytes, since the response middleware never sees a streamed body.
        def stream(payload, headers = {}, attempt: RetryTap::Attempt.new, frame: Spool::Null::Frame.new, &on_chunk)
          failure = StreamedFailure.new(self)
          terminating(frame) do
            connection.post(COMPLETION_PATH, payload) do |req|
              req.headers = headers.merge(req.headers) unless headers.empty?
              # On the context so RetryTap#retry_block reaches THIS request's
              # attempt and frame off the retried env, exactly as #sync_post does.
              req.options.context = (req.options.context || {}).merge(retry_attempt: attempt, wal_frame: frame)
              install_on_data(req, failure, frame, &on_chunk)
            end
          end
        rescue Provider::HTTP::Error => e
          failure.reraise(e)
        end

        # The models currently resident, each with the context length its runner
        # was loaded with.
        def process_status
          probe_connection.get(PROCESS_PATH)
        end

        # One model's metadata. A POST, because `/api/show` takes the model in a
        # body rather than a path segment (`api/types.go`'s ShowRequest).
        #
        # {#probe_connection}, not {#connection}: this runs at LAUNCH, in front
        # of the chronicle open, so it shares the probe's budget rather than
        # spending the completion path's four attempts on a number the caller
        # degrades without.
        def model_details(model)
          probe_connection.post(SHOW_PATH, { model: })
        end

        # The SAME vendored stack the completion path uses, rebuilt from a
        # config that differs only in patience. Not the second Faraday the
        # design forbids -- that prohibition is against a parallel, hand-rolled
        # client whose error mapping would drift from this one's. Built lazily,
        # so a provider that never asks for a window never opens it.
        def probe_connection
          @probe_connection ||= Provider::HTTP::Connection.new(self, probe_config, sink: @sink)
        end

        def api_base
          @config.ollama_api_base || DEFAULT_API_BASE
        end

        # Built from Configuration, because Configuration is the only thing the
        # wire path can reach. `Connection#provider_headers` asks THIS object,
        # so this is the sole live auth path; a {Deployment}'s own `#headers` is
        # a declaration checked against it by a spec, and is merged nowhere.
        #
        # Whether a key is any GOOD is deliberately not asked here: that would
        # be a SECOND definition of "there is a key", and two of those is how
        # they drift. {Deployment} refuses a nil, non-String,
        # whitespace-only or control-character key BY NAME, and on the bypass
        # path Configuration's generated setter already coerces a blank String
        # to nil. That setter special-cases `String` and nothing else, so a
        # non-String key set directly still reaches the wire as `Bearer 12345`
        # -- a backstop, not a validator.
        def headers
          key = @config.ollama_api_key
          key.nil? ? {} : { "Authorization" => "Bearer #{wire_safe(key)}" }
        end

        # Delegated, not re-derived, so the gate that decides this transport's
        # concurrency and the transport describing itself cannot disagree.
        def local? = Provider::Admission::Endpoint.local?(api_base)

        # The base pair delegate to the CLASS, so overriding only half would
        # leave a loopback transport answering `local?` and `remote?` both true.
        def remote? = !local?

        private

        # Writes the frame's terminator on BOTH exits, letting only `complete:`
        # differ.
        #
        # The `ensure`-shaped alternative -- close on success, let a raise leave
        # the frame open -- looks free, because {ResponseWal}'s reader resyncs
        # past a terminator-less frame. It is not: a
        # {ResponseWal::BufferedFrame}, which is what a round trip gets whenever
        # a sibling fiber holds the streaming slot, accumulates in memory and
        # reaches the file through `#close` and nowhere else. An unclosed
        # buffered frame is no record at all, so closing aborted is the
        # difference between salvaging a metered round trip that raised and
        # losing it.
        #
        # A CONSEQUENCE WORTH NAMING, because it looks like corruption at 3am: a
        # failed SYNC round trip writes one EMPTY aborted frame per attempt, so
        # a retried 500 leaves four zero-byte frames marked incomplete. That is
        # normal and inert -- salvage selects the last COMPLETE frame for the
        # digest, so aborted siblings are history rather than candidates.
        def terminating(frame)
          result = yield
          frame.close(complete: true)
          result
        rescue StandardError
          frame.close(complete: false)
          raise
        end

        # TWO GUARDS, AND THEY ARE NOT DUPLICATES -- the same shape as the
        # secret boundary's gate/filter/mask split. POLICY ("is this a
        # credential a human plausibly meant to set?") is {Deployment}'s,
        # the door every shipped caller comes through. WIRE FORMAT ("may this
        # value go into an HTTP header at all?") is owned HERE, because this is
        # the object that puts it there and CR/LF being illegal in a field value
        # is a fact about HTTP rather than about Ollama.
        #
        # The wire guard is what stands on the BYPASS path, where a
        # Configuration is built directly and no deployment is involved. There
        # Net::HTTP raised a bare `ArgumentError` -- outside {Lain::Error}, so
        # outside every rescue in the codebase -- with the live key quoted in
        # its message. Deleting either guard reopens a case the other never
        # covered.
        #
        # A NON-STRING KEY IS DELIBERATELY NOT REFUSED HERE. `Bearer 12345` is a
        # legal header value, so it is a policy fault rather than a wire-format
        # one, and importing that judgement here is exactly the second policy
        # validator that must not exist.
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
        # chunks straight to the NDJSON assembler.
        #
        # The failed arm deliberately does NOT call the vendored
        # `handle_failed_response`, which raises from inside this callback off a
        # status its `parse_streaming_error` GUESSES (500, or 529). That guess
        # is for an in-stream SSE `event: error`, where the response really did
        # return 200 -- but here the true status arrived in the headers before
        # any body byte, and a guessed 500 is in the retry allowlist, so a 404
        # was retried and then answered with the wrong status. On a response
        # already known to have failed there is nothing to raise from in here,
        # so this arm only accumulates and the one raise happens in #stream.
        #
        # The frame is appended BEFORE the assembler is fed, so the WAL records
        # what came off the wire rather than what survived parsing -- a chunk
        # that makes the assembler raise is exactly the one a salvage wants. The
        # failed-response arm does NOT tee: a non-2xx body belongs to
        # {StreamedFailure}, and copying it here would put an error page into a
        # frame a reader takes for a turn's bytes.
        def install_on_data(req, failure, frame, &on_chunk)
          handler = Provider::HTTP::Streaming::FaradayHandlers.build(
            on_chunk: lambda { |chunk, _env|
              frame.append(chunk)
              yield(chunk)
            },
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
