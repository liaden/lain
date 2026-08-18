# frozen_string_literal: true

require "json"

require_relative "ollama/encoding"
require_relative "ollama/retry_tap"
require_relative "ollama/stream_assembler"
require_relative "ollama/streamed_failure"
require_relative "ollama/transport"

module Lain
  class Provider
    # Ollama's native `/api/chat`, non-streaming. A free, local, temperature-0
    # bench arm -- a determinism oracle for tests and an exploration target on
    # the "Provider / model" axis.
    #
    # It is a neutral {Lain::Provider} (NOT the OpenAI-compat shim RubyLLM's
    # Ollama integration is): it encodes with {Ollama::Encoding} and drives the
    # vendored Faraday stack through {Transport}. The native path is chosen over
    # `/v1/...` because that OpenAI-compat surface is SSE + `finish_reason` +
    # `tool_call_id`, while the native one is NDJSON + `done_reason` +
    # tool_name-only correlation -- and mapping the native semantics honestly is
    # cheaper than adapting a shim tuned for OpenAI's models.
    #
    # == What the wire lacks, and how it is bridged
    #
    # Native `/api/chat` emits no tool-call id -- results correlate by
    # `tool_name` only. So a stable id is synthesized on decode (below), lives
    # purely on Lain's side, and {Ollama::Encoding} maps it back to a
    # `tool_name` when a tool_result returns to the wire. And `done_reason`'s
    # real enum is only "stop"/"length"/"" -- there is no "tool_calls" value --
    # so `:tool_use` is derived from the PRESENCE of tool_calls, not from
    # done_reason (both confirmed in references/ollama/).
    #
    # == What Ollama deliberately does not have
    #
    # It shares {ErrorWrapping} with the hosted arms but NOT {AnthropicWire} --
    # its wire is native `/api/chat` NDJSON, decoded by {Ollama::Encoding} and
    # this class's own #build_response. The rest of the asymmetry is stated
    # here rather than left to be inferred from an absent line, because a
    # silent divergence between providers is how a bench arm stops being
    # comparable:
    #
    # NO LONGER absent: a `channel:`. This arm used to take none, so retries
    # were not journaled: faraday-retry still ran (HTTP::Configuration's
    # vendored 3) but no {Telemetry::ProviderRetry} reached the Journal, and a
    # run's record showed one request where four attempts happened. The note
    # here said free/local spend made that tolerable and that comparing latency
    # across arms would not let it stay so. What ended it was neither: the
    # 2026-08-17 QA run hit a stalled server and waited **over 400 seconds
    # printing nothing at all** (F7a), which on the one arm whose honest shape
    # is a model thinking for six minutes is unreadable. {RetryTap} now journals
    # every attempt boundary, and -- the part T10 needs -- gives a retry
    # somewhere to DISCARD what the attempt it replaced accumulated.
    #
    # What that fixed, and what it still does not: {Frontend::Decorators.for}
    # now renders {Telemetry::ProviderRetry} live too (T4/F15), so a human
    # watching a retrying request sees the attempt as it happens, not only in
    # the Journal afterward -- but only on whichever Channel this Provider was
    # built with, and a subagent's still defaults to {Channel::Null} (wiring
    # that path is explicitly a different card's scope). Bounding the wait
    # itself, rather than narrating it, is T12's stall detection.
    #
    # deliberately absent: a timeout/retry envelope of its own -- unlike
    # {Anthropic#build_config}, this leaves the vendored ruby_llm defaults
    # (300s, 3 retries). A local model that thinks for six minutes is a real
    # shape, so the 300s is a live limit rather than a formality.
    #
    # deliberately absent: rate-limit backoff -- a local server sends no
    # `anthropic-ratelimit-*` headers, so there is nothing for
    # {AnthropicWire::RESET_HEADER_PARSER} to read.
    #
    # deliberately absent: a `spool:` -- no response WAL, so nothing on this arm
    # is salvageable after a crash.
    class Ollama < Provider
      include Encoding
      # APIError / APIStatusError, nested here and rooted at Lain::Error.
      include ErrorWrapping.under(Lain::Error)

      DEFAULT_MODEL = "qwen3:4b"

      # The NDJSON streaming path (below) makes :streaming honest. :thinking is
      # honest too (R5): `think` rides Request#extra onto its own top-level
      # wire field (Encoding#encode), and #decode_content already turns
      # `message.thinking` into a thinking block on both the sync and streamed
      # paths. :prompt_caching and :strict_tools stay off deliberately --
      # declaring one the native path cannot demonstrate would be a lying
      # capability in the one subsystem built to catch them, so the capability
      # policy's `:degrade` journals those gaps, which is the bench working as
      # designed.
      # `structured_output` here is grammar-CONSTRAINED decoding (the native `format`
      # field) -- a stronger guarantee than Anthropic's tool-forcing under the same
      # capability name. See Provider::AnthropicReference::CAPABILITIES.
      CAPABILITIES = %i[streaming thinking structured_output].freeze

      # @param transport [#sync_post] injected in specs; a real {Transport} over
      #   the vendored connection otherwise.
      # @param config [Provider::HTTP::Configuration, nil] injected in specs; otherwise built by
      #   {#build_config}, which sets only `ollama_api_base` -- no api key option, since Ollama
      #   is local.
      # @param channel [Lain::Channel] where {RetryTap}'s retry events land. The
      #   Null instance by default, so bench (which passes none) records exactly
      #   what it recorded before this arm learned to journal retries.
      # @param retries [RetryTap, nil] injected in specs; a real {RetryTap} over
      #   `channel:` otherwise. It has to be injectable rather than patched on
      #   afterwards: the Faraday middleware stack -- `retry_block` included --
      #   is snapshotted when the transport is built, so a tap swapped in after
      #   construction is never the one faraday-retry calls.
      # @param sink [Lain::Sink] where the transport's debug/log lines go
      # @param api_base [String, nil] overrides `ollama_api_base` (default
      #   http://localhost:11434); no api key -- Ollama is local.
      def initialize(transport: nil, config: nil, channel: Channel::Null.instance, retries: nil,
                     sink: Sink::Null.new, api_base: nil)
        super()
        @retries = retries || RetryTap.new(channel:)
        @config = journaled_retries(config || build_config(api_base:))
        @transport = transport || Transport.new(@config, sink:)
      end

      def capabilities = CAPABILITIES

      # No :prompt_caching capability, so no cache economics to report --
      # {CacheProfile::NO_CACHING} is the honest, flat-cost Null Object
      # answer, promoted off what used to be a per-provider
      # `NO_CACHING_PROFILE` Hash constant here (CAC-2/F1) into the neutral
      # {Lain::CacheProfile} home shared with every other provider.
      def cache_profile = CacheProfile::NO_CACHING

      # One round trip into a neutral Response. Streaming and non-streaming
      # converge on the same body Hash -- {StreamAssembler} reassembles the NDJSON
      # lines into the shape the non-streaming endpoint returns -- so both decode
      # through one #build_response (path parity).
      #
      # Both error arms come from {ErrorWrapping#wrapping_errors}, which records
      # why this arm bites hardest here: ollama is the DEFAULT summarizer
      # provider, "ollama is not running" is the ordinary case, and since the
      # span summarizer answers on the RENDER path a leak takes out the turn
      # rather than one summary. {#stream_body}'s JSON::ParserError arm sits
      # inside the block and passes through it untouched.
      def complete(request)
        wrapping_errors { build_response(request.stream ? stream_body(request) : sync_body(request)) }
      end

      # The window this server is actually serving `model` with, or nil.
      #
      # Ollama publishes two different context numbers and only one of them is
      # a denominator anything may divide by. `/api/show`'s
      # `model_info.<arch>.context_length` is the GGUF's TRAINED maximum --
      # 262,144 for qwen3-coder:30b -- while a loaded runner gets
      # min(trained, OLLAMA_CONTEXT_LENGTH, per-request num_ctx), which is
      # 32,768 on this box (DEBUGGING_OLLAMA.md:43). Divide occupancy by the
      # trained figure and it under-reports 8x, so compaction never fires --
      # the failure `context_window.rb:74-77` ranks as worse than the crash it
      # replaces. The trained number is therefore never returned, even though
      # it is the one that is always available: `/api/ps` states the served
      # figure or nobody does.
      #
      # So nil is the ORDINARY answer, not an error path. Ollama fixes a
      # runner's context at load time, so before the model is resident there is
      # genuinely no served window to report, and an unreachable server is the
      # everyday case on the arm that is also the default summarizer. Both
      # answer nil and leave {ContextWindow}'s conservative fallback in charge.
      #
      # == A CALLER SENDING num_ctx MUST take the min of this and its own
      #
      # This reports the window of the runner that is resident *now*, and
      # ollama reloads a runner whose `NumCtx` differs from the request's
      # (`sched.go`'s `needsReload`). So a runner left at 32,768 by `ollama
      # run`, by a sibling session, or by an earlier turn makes this answer
      # 32,768 while the very next request -- carrying an explicit `num_ctx` of
      # 8,192 -- is served 8,192. Reading this figure alone would then
      # over-estimate by 4x, by the exact mechanism the rest of this method
      # refuses. Any caller that sends `num_ctx` (an operator `--num-ctx`,
      # `Request#extra`) owns that `min`; this method cannot see the request.
      #
      # Measured 2026-08-17 on loopback: ~0.27ms warm, ~0.3ms with the server
      # down (one attempt, {Transport::PROBE_TIMEOUT_SECONDS}; the completion
      # path's budget would make that same case 790ms). Cheap enough to ask per
      # turn, which is what staying correct across a reload requires --
      # memoizing it is what makes the stale-runner case above permanent rather
      # than momentary.
      #
      # == The second rescue arm, and why it re-raises
      #
      # `wrapping_errors` catches {Provider::HTTP::Error} and {Faraday::Error},
      # so `rescue APIError` alone was narrower than the "nil is the ORDINARY
      # answer" contract above. It mattered most while
      # {CLI::Backend::WindowBook} could still reach a scheme-less
      # `--api-base` (`localhost:11434`, an ordinary typo) at all: it PARSES,
      # so construction succeeds, and Faraday's `build_exclusive_url` then
      # calls `end_with?` on the nil host -- a `NoMethodError` raised while
      # BUILDING the request, above Faraday's own error middleware, so
      # neither arm of `wrapping_errors` is reached.
      #
      # T5 moved that refusal a layer up: on the {CLI::Backend}-mediated
      # LAUNCH path, `--api-base` is now checked at {Backend}'s own
      # construction ({Backend::Endpoint}), so neither this method nor
      # {WindowBook} ever reaches a scheme-less or unparseable one anymore --
      # the run refuses before a {Backend} exists at all. This method's own
      # defence still earns its keep for a caller that constructs this class
      # DIRECTLY, skipping {Backend} entirely, as the examples below do: a
      # scheme-less base still parses and still needs the `NoMethodError`
      # rescue here, and a value that is not a URI at all still raises
      # `URI::InvalidURIError` straight out of `.new`, unabsorbed, for any
      # such caller.
      #
      # A bare `NoMethodError` arm would also swallow the one failure that must
      # stay loud: a transport that cannot answer `#process_status` at all is a
      # wiring bug, not an unreachable server, and a silent nil would hide it
      # (it did, for a canned transport in a seam spec). `#receiver` is what
      # tells the two apart -- the transport itself for the duck violation,
      # something deep inside Faraday for the typo -- so the wiring bug
      # re-raises and the operator's flag mistake answers nil, as every other
      # unknown here does.
      #
      # A black-holed host is the one case the budget, not the rescue, has to
      # answer for: `--api-base http://10.255.255.1:11434` costs the full
      # {Transport::PROBE_TIMEOUT_SECONDS} -- measured **2002 ms**, once, at
      # launch. That is the ceiling on what this method can cost a chat.
      #
      # @param model [String]
      # @return [Integer, nil]
      def context_window_tokens(model)
        served_context_length(model, wrapping_errors { @transport.process_status.body })
      rescue APIError
        nil
      rescue NoMethodError => e
        raise if e.receiver.equal?(@transport)

        nil
      end

      private

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

      # Each body path opens its OWN attempt, which is what makes the retry hook
      # reentrant across round trips sharing this Provider -- see {RetryTap}. A
      # sync body is one parsed Hash, so an abandoned attempt leaves nothing
      # behind and registers no rollback; the streaming path below is the one
      # with something to discard.
      def sync_body(request)
        @transport.sync_post(encode(request), attempt: @retries.open_attempt).body || {}
      end

      # The assembler is built out here while faraday-retry runs INSIDE
      # `@transport.stream`, so a retried attempt feeds the SAME assembler the
      # attempt it replaced was feeding. Left alone, that is a splice: a severed
      # attempt followed by a clean retry returned `ok`, done_reason "stop",
      # carrying both attempts' text (F7b). Hoisting the assembler inside the
      # block is not available -- the block is the chunk callback, called once
      # per chunk -- and NDJSON has no marker to re-sync on, so the discard has
      # to come from the retry itself. Registering #reset on this round trip's
      # {RetryTap::Attempt} is that: faraday-retry abandons the attempt, which
      # runs the reset, before the replacement's first chunk is fed.
      #
      # A corrupt NDJSON line is a wire-protocol violation, so it raises -- never
      # a silent skip (one torn line means the frame boundaries can no longer be
      # trusted). It is wrapped in APIError rather than escaping as a bare
      # JSON::ParserError for the same reason transport errors are: callers
      # rescue one provider-error family, and the original stays on `#cause`.
      def stream_body(request)
        assembler = StreamAssembler.new
        attempt = @retries.open_attempt { assembler.reset }
        @transport.stream(encode(request), attempt:) { |chunk| assembler.feed(chunk) }
        assembler.result
      rescue JSON::ParserError => e
        raise APIError, "corrupt NDJSON line in stream: #{e.message}"
      end

      def build_config(api_base:)
        config = Provider::HTTP::Configuration.new
        config.ollama_api_base = api_base unless api_base.nil?
        config
      end

      # Wires the tap onto whatever config the transport will be built from --
      # an INJECTED one included. That is deliberate and it is what makes the
      # seam testable at all: the retry ENVELOPE (interval, backoff, budget) is
      # snapshotted into the Faraday middleware when the transport is built, so
      # a caller who wants a different envelope has to hand one in BEFORE
      # construction, and journaling must not evaporate because they did. The
      # vendored 300s/3 envelope is otherwise left alone on purpose (see the
      # class docstring).
      #
      # It COPIES rather than wiring in place, so the caller's object is never
      # bound to this provider's tap. Wiring in place made a config single-use
      # without saying so: two providers built from ONE config both journal to
      # the FIRST one's channel, because `||=` finds the first tap's block
      # already there. Nothing in production injects a config
      # (`cli/backend.rb`, `oracle/secret_read.rb`), so that was a trap laid for
      # specs -- and T10 injects configs. `dup` is the same shallow copy
      # {Transport#probe_config} already takes of this object.
      #
      # The two callbacks are wired DIFFERENTLY, and the asymmetry is the point.
      #
      # `retry_block` COMPOSES: a caller's callback is threaded through
      # `then_call:` and runs in addition to the tap's, never instead of it.
      # This one carries a correctness invariant -- it is what abandons the
      # attempt, and so what stops a retried stream splicing onto the one it
      # replaced -- and a correctness invariant must not hang on a seam a caller
      # can displace. It did, briefly, and it was measurable: a config carrying
      # its own `retry_block` (which `ollama_spec.rb` ships) brought the whole
      # F7b splice back, returned as `:end_turn`. `||=` was the right wiring
      # while this block was only telemetry; it stopped being right the moment
      # T10 hung the discard on it.
      #
      # `exhausted_retries_block` keeps `||=`, because nothing but telemetry
      # hangs on it: exhaustion does not abandon -- the round trip raises and
      # the assembler is discarded with it -- so a caller who owns this callback
      # costs a Journal row and no correctness. A spec asserting on its own
      # exhaustion callback is testing faraday-retry's loop, and silently
      # replacing it would make that spec lie.
      def journaled_retries(config)
        config.dup.tap do |wired|
          wired.retry_block = @retries.retry_block(then_call: config.retry_block)
          wired.exhausted_retries_block ||= @retries.exhausted_block
        end
      end

      def build_response(body)
        message = body["message"] || {}
        Response.new(id: nil, model: body["model"], content: decode_content(message),
                     stop_reason: decode_stop_reason(body, message), usage: build_usage(body), raw: body)
      end

      # Order mirrors what a mixed assistant turn carries: reasoning first, then
      # visible text, then the calls -- thinking and text ride their own message
      # fields, tool_calls its own array.
      def decode_content(message)
        blocks = []
        blocks << { "type" => "thinking", "thinking" => message["thinking"] } unless blank?(message["thinking"])
        blocks << { "type" => "text", "text" => message["content"] } unless blank?(message["content"])
        Array(message["tool_calls"]).each_with_index { |call, index| blocks << tool_use_block(call, index) }
        blocks
      end

      # Ollama has no tool-call id, so one is synthesized from the call's
      # position -- deterministic and unique within the response, which is all
      # ToolRunner's id-keyed result matching needs (a later turn reusing the
      # same synthetic id is harmless: Encoding resolves tool_name in message
      # order, so each result names the tool its own turn called). A wire-
      # provided id is honored if one is ever present (forward-compat, and how
      # the parity harness replays canned ids); synthesis is the fallback.
      def tool_use_block(call, index)
        function = call["function"] || {}
        { "type" => "tool_use", "id" => call["id"] || "ollama-tool-#{index}",
          "name" => function["name"], "input" => parse_arguments(function["arguments"]) }
      end

      # Belief (b): native `/api/chat` returns arguments as a parsed object. The
      # String branch is belt-and-suspenders on Response#tool_uses' Hash
      # contract -- a String must never reach the Timeline.
      def parse_arguments(arguments)
        return arguments unless arguments.is_a?(String)

        JSON.parse(arguments)
      end

      # Presence of tool_calls forces :tool_use -- done_reason stays "stop" on a
      # tool turn. Otherwise map the two enum values Ollama can express and let
      # StopReason.normalize close the open enum ("" -> :unknown, and any
      # load/unload edge string likewise), so gate 6 stays total.
      def decode_stop_reason(body, message)
        return StopReason::TOOL_USE unless Array(message["tool_calls"]).empty?

        case body["done_reason"]
        when "stop" then StopReason::END_TURN
        when "length" then StopReason::MAX_TOKENS
        else StopReason.normalize(body["done_reason"])
        end
      end

      def build_usage(body)
        Usage.new(input_tokens: body["prompt_eval_count"], output_tokens: body["eval_count"])
      end

      def blank?(value)
        value.nil? || value == ""
      end
    end
  end
end
