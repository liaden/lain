# frozen_string_literal: true

require "json"

require_relative "ollama/decoding"
require_relative "ollama/encoding"
require_relative "ollama/retry_tap"
require_relative "ollama/stream_assembler"
require_relative "ollama/streamed_failure"
require_relative "ollama/deployment"
require_relative "ollama/transport"

module Lain
  class Provider
    # Ollama's native `/api/chat`. A free, local, temperature-0 bench arm -- a
    # determinism oracle for tests, an exploration target on the "Provider /
    # model" axis -- and, through {Deployment.cloud}, a metered hosted one.
    #
    # A neutral {Lain::Provider}, NOT the OpenAI-compat shim RubyLLM's Ollama
    # integration is. The native path is chosen over `/v1/...` because that
    # compat surface is SSE + `finish_reason` + `tool_call_id` while the native
    # one is NDJSON + `done_reason` + tool_name-only correlation, and mapping
    # the native semantics honestly is cheaper than adapting a shim tuned for
    # OpenAI's models.
    #
    # == What the wire lacks, and how it is bridged
    #
    # Native `/api/chat` emits no tool-call id -- results correlate by
    # `tool_name` only. So a stable id is synthesized on decode, lives purely
    # on Lain's side, and {Ollama::Encoding} maps it back to a `tool_name` when
    # a tool_result returns to the wire. And `done_reason`'s real enum is only
    # "stop"/"length"/"" -- there is no "tool_calls" value -- so `:tool_use` is
    # derived from the PRESENCE of tool_calls, not from done_reason (both
    # confirmed in references/ollama/).
    #
    # == What the deployment owns, and what is still absent
    #
    # It shares {ErrorWrapping} with the hosted arms but NOT {AnthropicWire}.
    # Timeout/retry envelope, authentication, the `/api/ps` and `/api/show`
    # probes and the capability set are all the {Deployment}'s to state,
    # because the two arms disagree: 300s/3 is a local model thinking for six
    # minutes, 120s/5 is a metered host whose ordinary failure is a 429.
    #
    # {RetryTap} journals every attempt boundary and -- the part the
    # retried-stream discard needs -- gives a retry somewhere to DISCARD what
    # the attempt it replaced put together. Narrating a retry is not cosmetic
    # here: a stalled server once waited over 400 seconds printing nothing at
    # all, which on the one arm whose honest shape is a model thinking for six
    # minutes is unreadable. Bounding that wait, rather than narrating it, is
    # the stall clock's job and not this arm's.
    #
    # `spool:` reached this class only once the arm stopped being free, because
    # that is when the absence stopped being cheap: a lost local round trip
    # costs a retry, a lost metered one is SPENT. A retry ROTATES the frame, so
    # a severed attempt and its replacement are two frames rather than one that
    # lies -- the splice defect again, in the spool instead of the assembler,
    # with the two discards registered independently so neither can displace
    # the other.
    #
    # STILL ABSENT: rate-limit backoff, because the header vocabulary the
    # native cloud path returns is unverified and naming an unseen header would
    # replace faraday-retry's working default with a guess
    # ({Deployment} states the case).
    class Ollama < Provider
      include Encoding
      include Decoding
      # APIError / APIStatusError, nested here and rooted at Lain::Error.
      include ErrorWrapping.under(Lain::Error)
      include Admitted

      DEFAULT_MODEL = "qwen3:4b"

      # Same refusal shape as {.deployment_free}: a keyword whose effect another
      # keyword silently swallows is refused rather than resolved, because the
      # resolution is invisible from every assertion the caller could write.
      RETRIES_OWN_THE_SPOOL = "retries: already owns the spool it was built with; " \
                              "pass spool: to the RetryTap instead"

      # `structured_output` here is grammar-CONSTRAINED decoding (the native
      # `format` field) -- a stronger guarantee than Anthropic's tool-forcing
      # under the same capability name. See
      # Provider::AnthropicReference::CAPABILITIES. :thinking is honest because
      # `think` rides Request#extra onto its own top-level wire field.
      # :prompt_caching and :strict_tools stay off deliberately: declaring one
      # the native path cannot demonstrate would be a lying capability in the
      # one subsystem built to catch them, so the capability policy's
      # `:degrade` journals those gaps instead.
      #
      # Read from the deployment rather than written out a third time.
      # `#capabilities` delegates, so a literal here would be a copy nothing
      # consults -- free to drift from the value actually answered while every
      # spec asserting against it stayed green. The constant survives because it
      # is what an outside reader asks for, and a deployment-independent answer
      # is now structural rather than a coincidence: both arms read the one
      # {Deployment::CAPABILITIES}, so there is nothing left to disagree.
      CAPABILITIES = Deployment::CAPABILITIES

      # Exactly `.new`, and deliberately adds nothing: the bare construction has
      # to keep meaning loopback, because
      # `spec/provider_construction_discipline_spec.rb` matches `.new` with
      # Ripper and `Oracle::SecretRead.tier` relies on that static guard. So
      # this is a synonym a NEW caller can reach for, never a replacement at an
      # existing site -- renaming one would delete the guard while looking like
      # a strengthening. That guard also keeps a hand-maintained list of factory
      # selectors, so a door named anything else slips past the check entirely
      # rather than tripping it.
      #
      # @param options [Hash] forwarded verbatim to {#initialize}
      # @option options [String] :api_base override the base this arm dials
      # @option options [Channel] :channel where retries and stalls are narrated
      # @option options [Channel] :journal where each round trip is recorded;
      #   omitting it yields an UNJOURNALED provider
      # @return [Ollama] a loopback provider, identical to `.new`
      def self.local(**options) = new(**deployment_free(options, "local"))

      # `api_key:` is REQUIRED rather than read from the environment here.
      # {Deployment.cloud} refuses a blank key by naming `OLLAMA_API_KEY` and
      # where to get one, which is the right message only if the caller that
      # read the variable is the one being told -- and that caller is the CLI,
      # not this class. A provider that reached for ENV itself would also make
      # its own construction untestable without mutating the environment.
      #
      # @param api_key [String] the subscription key, refused blank by {Deployment.cloud}
      # @param admission_width [Integer, nil] concurrent round trips this plan permits
      # @param options [Hash] forwarded verbatim to {#initialize}
      # @option options [String] :api_base override the base this arm dials
      # @option options [Channel] :channel where retries and stalls are narrated
      # @option options [Channel] :journal where each round trip is recorded;
      #   omitting it yields an UNJOURNALED provider
      # @return [Ollama] a provider dialling the cloud host
      def self.cloud(api_key:, admission_width: nil, **options)
        new(deployment: Deployment.cloud(api_key:, admission_width:),
            **deployment_free(options, "cloud"))
      end

      # A factory NAMES its deployment, so a second one in the same call is a
      # contradiction rather than an override.
      #
      # Forwarded blind, Ruby's later-wins keyword rule resolves it silently and
      # in the more dangerous direction: `Ollama.cloud(api_key:, deployment:
      # Deployment.local)` validates the cloud credential, discards the hosted
      # deployment it just built, and hands back a LOOPBACK provider whose
      # `admission_width` is nil -- an unbounded caller against a metered plan,
      # from a call that reads as explicitly cloud. Nothing downstream can
      # notice, which is {CLI::Backend::Endpoint}'s test for what must be
      # refused at construction.
      #
      # @param options [Hash] the forwarded keywords a factory was handed
      # @param factory [String] the factory's name, for the refusal message
      # @option options [Deployment] :deployment the contradiction this refuses
      # @return [Hash] `options` unchanged when it states no deployment
      # @raise [ArgumentError] when it does
      def self.deployment_free(options, factory)
        return options unless options.key?(:deployment)

        raise ArgumentError, "Ollama.#{factory} already states its deployment; " \
                             "pass deployment: to .new instead"
      end
      private_class_method :deployment_free

      # @param deployment [#api_base] WHOSE ollama this is. {Deployment.local}
      #   by DEFAULT, and the default is the contract: a bare construction
      #   still means loopback, so `Oracle::SecretRead.tier`'s guarantee is
      #   untouched by this keyword existing.
      # @param transport [#sync_post] injected in specs; a real {Transport} over
      #   the vendored connection otherwise.
      # @param config [Provider::HTTP::Configuration, nil] injected in specs; otherwise built by
      #   {#build_config} from the deployment. An injected one is taken AS GIVEN and the
      #   deployment never rewrites it -- a caller who hands in a whole configuration has
      #   already said what it is.
      # @param channel [Lain::Channel] where {RetryTap}'s retry events land
      # @param retries [RetryTap, nil] injected in specs; a real {RetryTap} over
      #   `channel:` otherwise. It has to be injectable rather than patched on
      #   afterwards: the Faraday middleware stack -- `retry_block` included --
      #   is snapshotted when the transport is built, so a tap swapped in after
      #   construction is never the one faraday-retry calls.
      # @param sink [Lain::Sink] where the transport's debug/log lines go
      # @param api_base [String, nil] overrides the base the deployment resolves
      #   to, applied AFTER the deployment; see {#build_config} for why the
      #   other order loses it silently.
      # @param queue [Boolean] whether this provider may WAIT for {Admission} to
      #   free a slot. Capacity is a property of the server, willingness to wait
      #   a property of the caller, which is why this is a constructor keyword
      #   and not an argument to {#complete}.
      #
      #   `false` is {Oracle::Eager}'s, and only its: it promises the turn that
      #   produced a tool result never waits on its summary, so a busy endpoint
      #   must SKIP the summary rather than queue it. Queueing there is the
      #   worse degradation -- a fire reaped at teardown burns its digest for
      #   the whole session -- while a skip is a miss
      #   {Compaction::SummarySnapshot} already reads as ordinary.
      # @param journal [#<<] where a {Telemetry::ProviderWait} lands when this
      #   provider QUEUES for capacity. Deliberately not `channel:`, which is
      #   the live frontend stream rather than the session's record.
      # @param spool [#open_frame, nil] where each round trip's raw response
      #   bytes are teed for salvage.
      #
      #   THE NIL DEFAULT IS LOAD-BEARING and is not the missing Null Object it
      #   looks like: it is the only thing that tells "passed no spool" apart
      #   from "passed a Null spool", which is what the refusal below needs. A
      #   `Spool::Null.new` default would make the two indistinguishable and the
      #   contradiction unrefusable. Every real caller still hands over a Null
      #   Object, so the coalesce is reached only by a bare construction.
      # @raise [ArgumentError] when `retries:` and `spool:` are both given --
      #   the tap is what OWNS the spool, so an injected tap makes the spool
      #   unreachable. Silently dropping it would build the WAL, hand it a real
      #   chronicle, and record nothing, which no assertion in a spec that
      #   injected both could see.
      def initialize(transport: nil, config: nil, channel: Channel::Null.instance, retries: nil,
                     sink: Sink::Null.new, api_base: nil, queue: true, journal: Channel::Null::INSTANCE,
                     deployment: Deployment.local, spool: nil)
        super()
        raise ArgumentError, RETRIES_OWN_THE_SPOOL if retries && spool

        @queue = queue
        @journal = journal
        @deployment = deployment
        @retries = retries || RetryTap.new(channel:, spool: spool || Spool::Null.new)
        @config = journaled_retries(config || build_config(api_base:))
        @transport = transport || Transport.new(@config, sink:)
      end

      def capabilities = @deployment.capabilities

      # No :prompt_caching capability, so no cache economics to report --
      # {CacheProfile::NO_CACHING} is the honest, flat-cost Null Object answer.
      # Both deployments give it today; the delegation is what leaves either arm
      # free to revise the claim on its own evidence.
      def cache_profile = @deployment.cache_profile

      # One round trip into a neutral Response. Streaming and non-streaming
      # converge on the same body Hash -- {StreamAssembler} reassembles the
      # NDJSON lines into the shape the non-streaming endpoint returns -- so
      # both decode through one #build_response.
      #
      # == Why {Admission} is taken HERE, and why it may not move
      #
      # This is the ONE boundary every round trip crosses, and taking capacity
      # anywhere else means enumerating callers -- which cannot be done:
      # {Oracle::SecretRead.tier} builds this class bare and accepts no injected
      # collaborator on purpose (that seam is the disclosure the whole rung
      # exists to prevent), so a gate handed in by {CLI::Backend} could never
      # cover it. Keyed by the endpoint this provider resolved for itself.
      #
      # It may not move DOWN, into {#stream_body} or the transport: the stall
      # clock arms on the first body chunk with a 30s grace, so a request queued
      # below that point would hold an armed clock while no server was sending
      # it anything and be killed for a silence admission itself caused.
      #
      # It may not move UP either, into `Agent#call_model` or {ModelCaller}:
      # `Compaction::Strategy::Summarizing#asked` awaits an oracle inside
      # `Agent#render_request`, which runs BEFORE `#complete` -- above this seam
      # that await is outside the slot, and above `call_model` it would re-enter
      # a non-reentrant gate from inside the held region and hang the session.
      #
      # The wrapping is INSIDE the slot so a retrying round trip -- faraday-retry
      # sits within the connection -- holds its slot for all four attempts rather
      # than freeing it between them. {Admission::Busy} is not an API failure and
      # deliberately passes {ErrorWrapping} by, naming the saturated endpoint.
      def complete(request)
        admitted { wrapping_errors { build_response(dispatch(request)) } }
      end

      # The window this server is actually serving `model` with, or nil.
      #
      # THE SERVED FIGURE, NEVER THE TRAINED ONE. `/api/show`'s
      # `model_info.<arch>.context_length` is the GGUF's trained maximum and is
      # 8x larger, so dividing occupancy by it means compaction never fires --
      # a worse failure than the crash compaction prevents. So nil is the
      # ORDINARY answer here rather than an error path: `/api/ps` states the
      # served figure or nobody does, and {ContextWindow}'s conservative
      # fallback takes over.
      #
      # A CALLER THAT SENDS num_ctx OWNS THE MIN of this and its own, because
      # this method cannot see the request. Asked per turn rather than memoized,
      # which is what staying correct across a runner reload requires -- both
      # rules, the measurements behind them, and what the probe costs against a
      # black-holed host are in docs/providers/ollama.md.
      #
      # == The second rescue arm, and why it re-raises
      #
      # `wrapping_errors` catches {Provider::HTTP::Error} and {Faraday::Error},
      # which is narrower than the "nil is the ORDINARY answer" contract above.
      # A scheme-less `--api-base` (`localhost:11434`, an ordinary typo) PARSES,
      # so construction succeeds, and Faraday's `build_exclusive_url` then calls
      # `end_with?` on the nil host -- a `NoMethodError` raised while BUILDING
      # the request, above Faraday's own error middleware, so neither arm of
      # `wrapping_errors` is reached. {CLI::Backend::Endpoint} now refuses that
      # flag before a Backend exists, but a caller who constructs this class
      # DIRECTLY still reaches it.
      #
      # A bare `NoMethodError` arm would swallow the one failure that must stay
      # loud: a transport that cannot answer `#process_status` at all is a
      # wiring bug, not an unreachable server, and a silent nil hid one for a
      # canned transport in a seam spec. `#receiver` tells the two apart -- the
      # transport itself for the duck violation, something deep inside Faraday
      # for the typo.
      #
      # A deployment with no loaded-runner concept answers before the request is
      # MADE, not by rescuing one: `/api/ps` is asked on the render path, so a
      # rescue would spend a round trip per denominator lookup against somebody
      # else's quota purely to rediscover a 404.
      #
      # @param model [String]
      # @return [Integer, nil]
      def context_window_tokens(model)
        return nil unless @deployment.runner_status?

        served_context_length(model, wrapping_errors { @transport.process_status.body })
      rescue APIError
        nil
      rescue NoMethodError => e
        raise if e.receiver.equal?(@transport)

        nil
      end

      # The GGUF's trained maximum for `model`, or nil.
      #
      # THE NUMBER {#context_window_tokens} REFUSES TO RETURN, behind its own
      # name so the two can never be mistaken for each other. A CEILING FOR
      # REFUSING A FLAG, NEVER A DENOMINATOR: its one caller compares against
      # it and discards it, and if it ever reaches
      # {ContextWindow::WindowResolution} the 8x under-report the pair exists
      # to prevent is back one layer up.
      #
      # The architecture is read from the body rather than assumed: the KV key
      # is `<general.architecture>.context_length`, so a hard-coded family name
      # would answer nil for every other model. Value type is checked, never
      # coerced -- `Integer("0x40000")` is 262,144, and a ceiling built by
      # coercion refuses flags that were fine.
      #
      # Same rescue set and same reasoning as {#context_window_tokens}, and its
      # OWN predicate: `/api/ps` and `/api/show` are two endpoints with two
      # meanings, and this one is reached EAGERLY at launch before the
      # chronicle is open -- the worst possible place to learn that a host does
      # not serve it.
      #
      # @param model [String]
      # @return [Integer, nil]
      def trained_context_tokens(model)
        return nil unless @deployment.model_metadata?

        trained_context_length(wrapping_errors { @transport.model_details(model).body })
      rescue APIError
        nil
      rescue NoMethodError => e
        raise if e.receiver.equal?(@transport)

        nil
      end

      private

      # {Admitted}'s collaborators. These are the CALLER's properties, which is
      # why they arrive at construction and not with a round trip.
      def queue_for_capacity? = @queue

      def wait_journal = @journal

      # The one {Admitted} collaborator that is the SERVER's property rather
      # than the caller's, which is why it comes from the deployment. The
      # loopback arm answers nil, meaning "nobody said", leaving {Admission}'s
      # locality rule in charge; only an endpoint locality gets wrong --
      # hosted, and hard-capacity-bounded -- states a number.
      def admission_width = @deployment.admission_width

      # The endpoint THIS provider will really talk to, which is the only honest
      # key: the `api_base` flag is shared by every tier, so it reads nil for a
      # bare construction and for a hosted one alike. Read off the same
      # Configuration {Transport#api_base} reads, with the same fallback, and
      # pinned equal by spec because the two live in different files.
      def resolved_endpoint = @config.ollama_api_base || Transport::DEFAULT_API_BASE

      # `model_info` is the GGUF KV table handed back nearly verbatim
      # (`routes.go`'s GetModelInfo), so the key is derived, not fixed.
      def trained_context_length(body)
        info = body.is_a?(Hash) ? body["model_info"] : nil
        tokens = info.is_a?(Hash) ? info["#{info["general.architecture"]}.context_length"] : nil
        tokens if tokens.is_a?(Integer) && tokens.positive?
      end

      # Upstream declares this field `ContextLength int` (`api/types.go`), so a
      # value that is not already an Integer means the body is not ollama's.
      # `Integer()` is deliberately NOT used to coerce one: it reads "0x40000"
      # as 262,144 -- the exact 8x over-estimate this method exists to refuse --
      # and truncates a Float besides. Both are the forbidden direction.
      def served_context_length(model, body)
        runner = loaded_runners(body).find { |entry| serves?(entry, model.to_s) }
        tokens = runner.to_h["context_length"]
        tokens if tokens.is_a?(Integer) && tokens.positive?
      end

      # Non-Hash entries are dropped rather than indexed. `api_base:` can point
      # at a proxy or at the wrong service entirely, and this answers on the
      # RENDER path -- a `TypeError` out of a denominator lookup would take out
      # the turn, which is the one thing nil exists to prevent.
      def loaded_runners(body)
        body.is_a?(Hash) ? Array(body["models"]).grep(Hash) : []
      end

      # Only `model`. The `/api/ps` handler assigns `name` and `model` from the
      # same `DisplayShortest()` value (`routes.go`), so the second key carries
      # nothing the first does not -- and on a body where they disagree, reading
      # it would answer with ANOTHER model's window. `:latest` is the tag ollama
      # appends to an untagged request before printing it back.
      def serves?(entry, model)
        [model, "#{model}:latest"].include?(entry["model"])
      end

      # The Provider opens the frame because the Provider is what holds the
      # REQUEST -- a frame is keyed by `request.digest`, and the transport is
      # handed an encoded payload it cannot re-derive one from. Keeping the
      # transport digest-blind is the same rule that put the rotation in
      # {RetryTap} rather than in the connection.
      def dispatch(request)
        frame = @retries.open_frame(request_digest: request.digest)
        request.stream ? stream_body(request, frame) : sync_body(request, frame)
      end

      # Each body path opens its OWN attempt, which is what makes the retry hook
      # reentrant across round trips sharing this Provider -- see {RetryTap}. A
      # sync body is one parsed Hash, so an abandoned attempt leaves nothing
      # behind and registers no rollback; the streaming path below is the one
      # with something to discard.
      def sync_body(request, frame)
        @transport.sync_post(encode(request), attempt: @retries.open_attempt, frame:).body || {}
      end

      # The assembler is built out here while faraday-retry runs INSIDE
      # `@transport.stream`, so a retried attempt feeds the SAME assembler the
      # attempt it replaced was feeding. Left alone, that is a splice: a severed
      # attempt followed by a clean retry returned `ok`, done_reason "stop",
      # carrying both attempts' text. Hoisting the assembler inside the block is
      # not available -- the block is the chunk callback, called once per chunk
      # -- and NDJSON has no marker to re-sync on, so the discard has to come
      # from the retry itself. Registering #reset on this round trip's
      # {RetryTap::Attempt} is that: faraday-retry abandons the attempt, which
      # runs the reset, before the replacement's first chunk is fed.
      #
      # A corrupt NDJSON line is a wire-protocol violation, so it raises -- never
      # a silent skip (one torn line means the frame boundaries can no longer be
      # trusted). It is wrapped in APIError rather than escaping as a bare
      # JSON::ParserError for the same reason transport errors are: callers
      # rescue one provider-error family, and the original stays on `#cause`.
      def stream_body(request, frame)
        assembler = StreamAssembler.new
        attempt = @retries.open_attempt { assembler.reset }
        @transport.stream(encode(request), attempt:, frame:) { |chunk| assembler.feed(chunk) }
        assembler.result.tap { note_truncated_stream(assembler, request) }
      rescue JSON::ParserError => e
        raise APIError, "corrupt NDJSON line in stream: #{e.message}"
      end

      # The witness for a stream that never said it was finished. NDJSON puts
      # `done` on its last line and nothing earlier says how many lines to
      # expect, so a severed connection reassembles into a body shape-identical
      # to a complete turn -- and every reader above here sees a turn that
      # merely stopped oddly. The assembler takes no arguments and holds no
      # channel, so the reading is made there and the record is cut here, where
      # the journal is.
      #
      # It reports and does not repair: the body is handed on untouched, because
      # the failure this was built from was a content-bearing turn and losing
      # the answer would be the worse defect.
      #
      # Scoped to the attempt actually RETURNED. This assembler is the one whose
      # bytes reached the caller, and #reset zeroed its counters on every
      # discard, so a severed attempt that faraday-retry cleanly replaced has
      # nothing left here to record -- a record for it would name a stream
      # nobody was served.
      #
      # The digest is added HERE and nowhere lower, because it is the one part
      # of the record the assembler cannot know. Without it the line is
      # unjoinable: this Provider is constructed once and reused, the chat tier
      # and the summarizer tier sharing it for a whole session, so several round
      # trips interleave on one channel and `model` plus adjacency cannot say
      # which of forty turns died.
      def note_truncated_stream(assembler, request)
        reading = assembler.truncation
        return if reading.nil?

        @journal << Telemetry::TruncatedStream.new(**reading, request_digest: request.digest)
      end

      # THE DEPLOYMENT FIRST, THE FLAG SECOND, and the order is the whole
      # correctness of this method. `apply` writes a COMPLETE position
      # unconditionally -- base, credential and envelope -- so one arm's Bearer
      # can never end up beside another's base. The cost is that `apply` cannot
      # honour `--api-base`: it cannot tell an operator's flag from the previous
      # deployment's write, and only this method knows whether `api_base:` was
      # passed. Reversed, the deployment silently overwrites the flag with no
      # error anywhere.
      def build_config(api_base:)
        config = @deployment.apply(Provider::HTTP::Configuration.new)
        config.ollama_api_base = api_base unless api_base.nil?
        config
      end

      # Wires the tap onto whatever config the transport will be built from, an
      # INJECTED one included: the retry ENVELOPE is snapshotted into the
      # Faraday middleware when the transport is built, so a caller who wants a
      # different envelope has to hand one in BEFORE construction, and
      # journaling must not evaporate because they did.
      #
      # It COPIES rather than wiring in place, so the caller's object is never
      # bound to this provider's tap. Wiring in place made a config single-use
      # without saying so: two providers built from ONE config both journal to
      # the FIRST one's channel, because `||=` finds the first tap's block
      # already there.
      #
      # The two callbacks are wired DIFFERENTLY, and the asymmetry is the point.
      # `retry_block` COMPOSES through `then_call:` because it carries a
      # correctness invariant -- it is what abandons the attempt, and so what
      # stops a retried stream splicing onto the one it replaced. A config
      # carrying its own `retry_block` brought the whole splice back, returned
      # as `:end_turn`, while this was wired with `||=`.
      #
      # `exhausted_retries_block` keeps `||=` because nothing but telemetry
      # hangs on it: exhaustion does not abandon -- the round trip raises and
      # the assembler is discarded with it -- so a caller who owns this callback
      # costs a Journal row and no correctness.
      def journaled_retries(config)
        config.dup.tap do |wired|
          wired.retry_block = @retries.retry_block(then_call: config.retry_block)
          wired.exhausted_retries_block ||= @retries.exhausted_block
        end
      end
    end
  end
end
