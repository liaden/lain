# frozen_string_literal: true

module Lain
  # Why a model stopped, normalized across providers.
  #
  # Exactly the values Anthropic's non-beta `StopReason` enum can produce,
  # verified against anthropic-1.55.0. What is NOT here matters:
  # `:model_context_window_exceeded` and `:compaction` exist only on the Beta
  # enum, so coding against them on the non-beta path waits for an event that
  # never arrives, while `:stop_sequence` does occur and is easy to forget.
  #
  # The wire enums are non-exhaustive, so an unrecognized value passes through
  # rather than raising, and `:unknown` is what CLOSES that open enum before the
  # machine ever sees a reason. Normalizing first is what lets
  # {Agent::LoopMachine} declare one event per value in `ALL` and fire it
  # directly instead of falling through a `case`'s `else`.
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
end
