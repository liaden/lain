# frozen_string_literal: true

module Lain
  module CLI
    # Flag defaults read from the environment, so a project can pin its provider
    # and model in a `direnv` `.envrc` instead of retyping them on every
    # invocation.
    #
    # == Two places a reader sits
    #
    # Thor uses a `default:` only when the flag is absent, so an env-backed
    # `default:` would already mean "explicit flag beats env beats built-in
    # default".
    #
    # The run-profile flags cannot sit there. A `default:` makes a typed
    # `--provider anthropic` and silence the same parse, and a resumed or forked
    # chat has to know which fields were typed before its recorded profile
    # answers the rest. Those flags declare no default, and `exe/lain`'s
    # `ModelFlags.profile` reads these same variables for the untyped fields
    # instead ({RunProfile#with_defaults}). Do not move them back into the slot.
    #
    # == What is deliberately NOT configurable here
    #
    # The environment may say how the model answers; it may never say what lain
    # is allowed to do, or whether it keeps a record. So neither auto-approval
    # shape (`auto` approval and the `--auto-approve` layer) nor `--journal`
    # is readable here. A stray `export` in a directory's `.envrc` would
    # silently disable the approval gate for every session started there, and
    # the failure is invisible -- tool calls simply stop being asked about; a
    # session that silently stopped journaling looks exactly like one that ran
    # cheaply. Both stay reachable per invocation, where they are visible.
    #
    # == Garbage fails loudly
    #
    # A typo'd `LAIN_NUM_CTX=lots` refuses by name rather than falling back
    # to the built-in default: a silent answer to a malformed question is the
    # one outcome nobody can debug. An UNSET variable is not garbage -- it is
    # absence, and takes the default.
    module EnvDefaults
      # Every name this module is read for, sorted; the one list the pane
      # preamble forwards.
      READ = %w[LAIN_API_BASE LAIN_MODEL LAIN_NUM_BATCH LAIN_NUM_CTX LAIN_PROVIDER].freeze

      # Names that were env defaults and are flags only now; moving one into
      # {READ} and back into an `exe/lain` call is the whole restore.
      RETIRED = %w[
        LAIN_KEEP_ALIVE LAIN_MAX_TOKENS LAIN_SEED LAIN_SUMMARIZER_MAX_TOKENS
        LAIN_SUMMARIZER_MODEL LAIN_SUMMARIZER_PROVIDER LAIN_TEMPERATURE
      ].freeze

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

      # Integer when it reads as one, Float otherwise, so `LAIN_NUM_CTX` and a
      # fractional name share one reader. nil is the refusal signal, which
      # keeps the raise at the one call site above.
      def number(raw)
        Integer(raw, exception: false) || Float(raw, exception: false)
      end
    end
  end
end
