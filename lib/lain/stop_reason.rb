# frozen_string_literal: true

module Lain
  # Why a model stopped, normalized across providers -- and, one tier wider,
  # every reason the loop can route.
  #
  # `KNOWN` is the WIRE vocabulary: exactly the values Anthropic's non-beta
  # `StopReason` enum can produce, verified against anthropic-1.55.0. What is
  # NOT there matters: `:model_context_window_exceeded` and `:compaction` exist
  # only on the Beta enum, so coding against them on the non-beta path waits
  # for an event that never arrives, while `:stop_sequence` does occur and is
  # easy to forget.
  #
  # `ALL` is the MACHINE vocabulary. It adds `:unknown`, which CLOSES the wire's
  # open enum before the machine ever sees a reason, and `:malformed`, which no
  # provider sends: it is a provider's own reading that a reply which decoded
  # cleanly is nonetheless unusable -- a tool call written as prose, which the
  # wire calls an ordinary end of turn. Normalizing first is what lets
  # {Agent::LoopMachine} declare one event per value in `ALL` and fire it
  # directly instead of falling through a `case`'s `else`.
  #
  # So two entry points. {.normalize} reads a WIRE value and can only ever
  # answer from `KNOWN` or `:unknown`, so no provider string spells its way into
  # a machine-only reason. {.admit} is what {Response} runs: a Symbol already in
  # `ALL` is a reason something typed and passes through; anything else --
  # every String among it, since `ALL` holds only Symbols -- is still a wire
  # value. The residual gap is exactly one value: an SDK that
  # hands over a Symbol, rather than the String JSON carries, and hands over
  # literally `:malformed`, would be admitted as lain's reading. Anthropic has
  # no such reason, and its live paths pass Strings.
  module StopReason
    END_TURN = :end_turn
    TOOL_USE = :tool_use
    MAX_TOKENS = :max_tokens
    STOP_SEQUENCE = :stop_sequence
    PAUSE_TURN = :pause_turn
    REFUSAL = :refusal
    UNKNOWN = :unknown
    MALFORMED = :malformed

    KNOWN = [END_TURN, TOOL_USE, MAX_TOKENS, STOP_SEQUENCE, PAUSE_TURN, REFUSAL].freeze
    ALL = (KNOWN + [UNKNOWN, MALFORMED]).freeze

    def self.normalize(value)
      symbol = value&.to_sym
      KNOWN.include?(symbol) ? symbol : UNKNOWN
    end

    def self.admit(value)
      ALL.include?(value) ? value : normalize(value)
    end
  end
end
