# frozen_string_literal: true

module Lain
  module CLI
    # Flag defaults read from the environment, so a project can pin its provider
    # and model in a `direnv` `.envrc` instead of retyping them on every
    # invocation.
    #
    # == Precedence comes free, and that is why this sits in the `default:` slot
    #
    # Thor uses a `default:` only when the flag is absent, so
    # `default: EnvDefaults.string("LAIN_PROVIDER", "anthropic")` already means
    # "explicit flag beats env beats built-in default" without anything
    # comparing the parsed options against the defaults afterward -- which is the
    # version of this that cannot tell `--provider anthropic` from silence.
    #
    # == What is deliberately NOT configurable here
    #
    # The line is: **the environment may say how the model answers; it may never
    # say what lain is allowed to do, or whether it keeps a record.**
    #
    # * `--yolo` / auto-approval. A stray `export` in a directory's `.envrc`
    #   would silently disable the approval gate for every session started
    #   there, and the failure is invisible -- tool calls simply stop being
    #   asked about. Approving without being asked is a decision worth typing.
    # * `--journal`. The Journal is the experiment record and usage accounting
    #   reads it; a session that silently stopped journaling looks exactly like
    #   one that ran cheaply.
    #
    # Both are reachable by flag, per invocation, where they are visible.
    #
    # == Garbage fails loudly
    #
    # A typo'd `LAIN_MAX_TOKENS=lots` refuses by name rather than falling back to
    # the built-in default, which is the same reasoning that kept
    # `StringInquirer` out of the state machine (CLAUDE.md): a silent answer to a
    # malformed question is the one outcome nobody can debug. An UNSET variable
    # is not garbage -- it is absence, and takes the default.
    module EnvDefaults
      module_function

      # @param name [String] the variable, `LAIN_`-prefixed by convention
      # @param fallback [String, nil] used when the variable is unset or empty
      # @return [String, nil]
      def string(name, fallback = nil)
        value = ENV.fetch(name, nil)
        value.nil? || value.strip.empty? ? fallback : value.strip
      end

      # @param name [String] the variable
      # @param fallback [Numeric, nil] used when the variable is unset or empty
      # @return [Numeric, nil]
      # @raise [Lain::Error] when set to something that is not a number
      def numeric(name, fallback = nil)
        raw = string(name)
        return fallback if raw.nil?

        number(raw) or raise Error, "#{name}=#{raw.inspect} is not a number -- unset it, or give it one"
      end

      # Integer when it reads as one, Float otherwise, so `LAIN_MAX_TOKENS` and
      # `LAIN_TEMPERATURE` share one reader. nil is the refusal signal; `Float()`
      # would raise here and be caught, but `Integer(exception: false)` reads the
      # same way for both and keeps the raise in one place.
      def number(raw)
        Integer(raw, exception: false) || Float(raw, exception: false)
      end
    end
  end
end
