# frozen_string_literal: true

module Lain
  # The seam between Lain and a model API: one round trip, no loop.
  #
  # Lain owns the loop. Both SDKs offer to own it for us -- Anthropic's
  # `beta.messages.tool_runner`, RubyLLM's `Chat#complete` -- and both are
  # declined, because the loop is the object of study. A Provider therefore does
  # exactly three things: declare what it can do, encode a neutral {Lain::Request}
  # into its own wire payload, and complete one request into a neutral
  # {Lain::Response}.
  #
  # == Capabilities are machine-checked, not documented
  #
  # Providers are deliberately NOT symmetric. RubyLLM 1.16 has no server-side
  # tools, no MCP connector, no memory tool, no Agent Skills, no Batches. If you
  # A/B a prompt across two providers and half your context tactics silently
  # became no-ops on one of them, the comparison is a lie. So a Context combinator
  # declares what it `requires`, a Provider declares what it `capabilities`, and
  # the mismatch is resolved by an explicit policy (:strict raises, :degrade
  # no-ops loudly and records the degradation in the Journal) rather than by
  # nobody noticing.
  class Provider
    class Unsupported < Error; end

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
    ].freeze

    # @return [Array<Symbol>] a subset of {CAPABILITIES}
    def capabilities
      raise NotImplementedError, "#{self.class} must declare #capabilities"
    end

    def supports?(capability)
      capabilities.include?(capability)
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
    def complete(_request)
      raise NotImplementedError, "#{self.class} must implement #complete"
    end

    def to_s
      "#<#{self.class} #{capabilities.sort.join(", ")}>"
    end
    alias inspect to_s
  end
end

require_relative "provider/anthropic_encoding"
require_relative "provider/anthropic"
require_relative "provider/http"
require_relative "provider/anthropic_raw"
require_relative "provider/ollama"
require_relative "provider/mock"
