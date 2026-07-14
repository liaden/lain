# frozen_string_literal: true

module Lain
  # Why a model stopped, normalized across providers.
  #
  # These are exactly the values Anthropic's non-beta `StopReason` enum can
  # produce, verified against anthropic-1.55.0. Note what is NOT here:
  # `:model_context_window_exceeded` and `:compaction` exist only on the Beta
  # enum, so coding against them on the non-beta path would be waiting for an
  # event that never arrives. `:stop_sequence` conversely does occur and is easy
  # to forget.
  #
  # The wire enums are non-exhaustive: an unrecognized value passes through
  # rather than raising. `:unknown` is not a pre-state-machine holdover left to
  # clean up -- it is what CLOSES the wire's open enum before the machine ever
  # sees a reason. `normalize` running first is what lets {Agent::LoopMachine}
  # declare one event per value in `ALL`, `:unknown` included, and fire it
  # directly instead of falling through a `case`'s `else` (gate 6 totality; see
  # the transition comment in `agent/loop_machine.rb`).
  module StopReason
    END_TURN = :end_turn
    TOOL_USE = :tool_use
    MAX_TOKENS = :max_tokens
    STOP_SEQUENCE = :stop_sequence
    PAUSE_TURN = :pause_turn
    REFUSAL = :refusal
    UNKNOWN = :unknown

    KNOWN = [END_TURN, TOOL_USE, MAX_TOKENS, STOP_SEQUENCE, PAUSE_TURN, REFUSAL].freeze
    ALL = (KNOWN + [UNKNOWN]).freeze

    def self.normalize(value)
      symbol = value&.to_sym
      KNOWN.include?(symbol) ? symbol : UNKNOWN
    end
  end

  # A model's reply, in Lain's vocabulary. Providers translate into this; nothing
  # downstream ever touches a provider's own response type.
  #
  # `content` holds the FULL block list -- text, thinking, and tool_use alike --
  # in normalized wire form. Correctness gate 1: the whole thing is what gets
  # appended to the Timeline. Extracting just the text and discarding thinking or
  # tool_use blocks corrupts the very next turn.
  #
  # `raw` carries the provider's own object for debugging. It is deliberately not
  # part of #digest.
  Response = Data.define(:id, :model, :content, :stop_reason, :usage, :raw) do
    def initialize(content:, stop_reason:, id: nil, model: nil, usage: Usage.zero, raw: nil)
      super(
        id: id&.to_s&.freeze,
        model: model&.to_s&.freeze,
        content: Canonical.normalize(content),
        stop_reason: StopReason.normalize(stop_reason),
        usage: usage,
        raw: raw
      )
    end

    def blocks_of_type(type)
      content.select { |block| block["type"] == type.to_s }
    end

    # Every tool_use block, with `input` already a parsed Hash.
    #
    # The Provider is responsible for guaranteeing that: on Anthropic's STREAMING
    # path with raw-hash tool schemas, `tool_use.input` arrives as a raw JSON
    # String rather than a Hash, while non-streaming `create` returns it parsed.
    # Nothing above the Provider should ever have to know that.
    def tool_uses
      blocks_of_type("tool_use")
    end

    def tool_use?
      stop_reason == StopReason::TOOL_USE
    end

    def text
      blocks_of_type("text").map { |block| block["text"] }.join
    end

    def digest
      Canonical.digest({ "content" => content, "stop_reason" => stop_reason.to_s })
    end

    def to_s
      "#<Lain::Response #{stop_reason} blocks=#{content.size} tools=#{tool_uses.size}>"
    end
    alias_method :inspect, :to_s
  end
end
