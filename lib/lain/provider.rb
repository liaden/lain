# frozen_string_literal: true

module Lain
  # The seam between Lain and a model API: one round trip, no loop.
  #
  # Lain owns the loop. Both SDKs offer to own it for us -- Anthropic's
  # `beta.messages.tool_runner`, RubyLLM's `Chat#complete` -- and both are
  # declined, because the loop is the object of study. A Provider therefore does
  # exactly three things: declare what it can do, encode a neutral
  # {Lain::Request} into its own wire payload, and complete one request into a
  # neutral {Lain::Response}.
  #
  # **Capabilities are machine-checked, not documented.** Providers are
  # deliberately NOT symmetric, and if you A/B a prompt across two of them while
  # half your context tactics silently became no-ops on one, the comparison is a
  # lie. So a Context combinator declares what it `requires`, a Provider
  # declares its `capabilities`, and the mismatch is resolved by an explicit
  # policy (:strict raises, :degrade no-ops loudly and records the degradation
  # in the Journal) rather than by nobody noticing.
  class Provider
    class Unsupported < Error; end
    include Inspectable

    # Every capability any provider may declare. Naming them in one place is what
    # lets `Compare` refuse to compare two runs whose degraded sets differ.
    CAPABILITIES = %i[
      streaming
      prompt_caching
      strict_tools
      thinking
      parallel_tool_use
      server_compaction
      server_context_editing
      server_tools
      structured_output
    ].freeze

    # @return [Array<Symbol>] a subset of {CAPABILITIES}
    def capabilities
      raise NotImplementedError, "#{self.class} must declare #capabilities"
    end

    def supports?(capability)
      capabilities.include?(capability)
    end

    # This provider's prompt-cache economics -- see {CacheProfile}. Abstract
    # like {#capabilities}, so a provider that has not declared its own fails
    # loudly rather than silently handing back Anthropic's numbers or nil.
    def cache_profile
      raise NotImplementedError, "#{self.class} must declare #cache_profile"
    end

    # How many tokens this model can take HERE -- on the endpoint this provider
    # is actually pointed at -- or nil when the provider cannot say.
    #
    # Deliberately NOT abstract like {#capabilities} and {#cache_profile}: those
    # are facts every arm knows about itself, while this is a fact about a
    # SERVER most providers have no endpoint to ask. nil is a real answer, and
    # the one that leaves {ContextWindow}'s conservative fallback in charge.
    #
    # The asymmetry governing every implementation: under-estimating makes
    # compaction fire early, over-estimating makes it never fire at all. So a
    # provider that can see only a number LARGER than the served window -- a
    # model's trained maximum, say -- must answer nil, not that number.
    #
    # @param _model [String] the model the answer is about; a served window is
    #   per-model, not per-endpoint
    # @return [Integer, nil]
    def context_window_tokens(_model)
      nil
    end

    # The largest window this model could EVER be served, or nil when the
    # provider cannot say.
    #
    # A CEILING FOR REFUSING A FLAG, NEVER A DENOMINATOR -- which is why it is a
    # second method rather than a fallback inside {#context_window_tokens}. The
    # two differ by 8x on this box (qwen3-coder:30b is trained to 262,144 and
    # served 32,768), and dividing occupancy by the larger is exactly the
    # never-fires failure the method above refuses. Nothing may pass this to
    # {ContextWindow::WindowResolution}; {CLI::Backend} reads it to ask whether
    # an operator's `--num-ctx` is above what any runner could serve, then
    # throws it away.
    #
    # Unlike the served window this is a property of the model FILE, knowable
    # as soon as a server can be asked, which is what lets the refusal happen
    # at launch rather than on the first turn. nil is a real answer here too:
    # a provider publishing no trained maximum must not block a launch.
    #
    # @param _model [String]
    # @return [Integer, nil]
    def trained_context_tokens(_model)
      nil
    end

    # Raise unless the capability is present. The message names the provider, so
    # a degraded bench run says which arm lost the tactic.
    def require!(capability)
      return true if supports?(capability)

      raise Unsupported, "#{self.class} does not support #{capability.inspect}"
    end

    # The exact payload this provider would send. Separated from {#complete} so
    # a Request can be byte-diffed, and a prompt-cache prefix reasoned about,
    # without spending a token.
    def encode(_request)
      raise NotImplementedError, "#{self.class} must implement #encode"
    end

    # One round trip.
    # @param request [Lain::Request]
    # @return [Lain::Response]
    def complete(request)
      raise NotImplementedError, "#{self.class} must implement #complete"
    end

    # to_s is the human-facing projection; inspect keeps the class-tagged,
    # debug-oriented form -- the DegradedSet convention.
    def to_s
      capabilities.sort.join(", ")
    end
  end
end

require_relative "provider/admission"
require_relative "provider/admitted"
require_relative "provider/journaled"
require_relative "provider/stream_started_signal"
require_relative "provider/error_wrapping"
require_relative "provider/anthropic_encoding"
require_relative "provider/anthropic_wire"
# The official-SDK arm (Provider::AnthropicReference) is NOT here. It is an
# `#encode` differential ORACLE that no run constructs -- every hosted path goes
# through a raw arm over the vendored Faraday transport -- so it lives in
# spec/support/provider_oracles/, and the `anthropic` gem is a test dependency
# rather than a runtime one.
require_relative "provider/http"
require_relative "provider/spool/null"
require_relative "provider/spool/rotating_frame"
require_relative "provider/response_wal"
require_relative "provider/anthropic"
require_relative "provider/ollama"
require_relative "provider/mock"
require_relative "provider/unreachable"
