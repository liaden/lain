# frozen_string_literal: true

module Lain
  module CLI
    class Backend
      # A `--num-ctx` larger than any runner could ever serve. Raised by
      # {NumCtx#tokens}, at construction, for {InvalidCeiling}'s and
      # {InvalidEndpoint}'s reason: the flag is well-formed, so nothing
      # downstream refuses it, and the number was silently adopted as the run's
      # whole denominator instead. Measured: `--num-ctx 999999` on a model
      # trained to 262,144 journaled `window=999999 provenance="probed"` while
      # ollama served 262,144.
      class UnservableWindow < Error; end

      # THE WHOLE OF WHAT `--num-ctx` MEANS: an optional per-request context
      # length, refused two ways, in the flag's own name. {Endpoint} is the
      # precedent -- one object owning one flag -- and {Backend} could not have
      # absorbed a second validation anyway without loosening a Metrics limit,
      # which CLAUDE.md forbids and which was right to forbid here: looking a
      # ceiling up off a live server is not something a flag bag should do.
      #
      # Two passes, and their order is load-bearing:
      #
      # 1. **Non-positive is refused by {Ceiling}**, so the positivity rule for
      #    every token knob stays in one place and the message names the same
      #    flag it always did. First, because `--num-ctx 0` is a mistake
      #    whatever the model was trained to -- reordering would make the error
      #    an operator sees depend on whether a server happened to be up.
      # 2. **Above the trained maximum is refused here.** An operator's
      #    `--num-ctx` is a REQUEST, not a measurement, and there is exactly one
      #    number it can be checked against before any runner exists: the
      #    maximum the weights were trained for.
      #
      # == The trained maximum is a CEILING, NEVER A DENOMINATOR
      #
      # {Provider#trained_context_tokens} is a second accessor precisely so the
      # two numbers cannot be confused. The trained figure is 262,144 for
      # qwen3-coder:30b while the runner serves 32,768; divide occupancy by the
      # trained one and it under-reports 8x, so `:approaching_window` never
      # fires -- the failure `context_window.rb` ranks as worse than the crash
      # the conservative fallback replaces. This object compares against it and
      # answers the REQUEST, so nothing it touches reaches
      # {ContextWindow::WindowResolution}.
      #
      # == Degrade, do not refuse, when no ceiling is knowable
      #
      # Only ollama publishes a trained maximum, and only when it is running.
      # nil is a real answer, so the refusal fires just where a maximum is known
      # AND exceeded -- and every provider-resolution failure is deferred to
      # {Backend#provider}'s real callers, exactly as {WindowBook#book} defers
      # them, because a provider that cannot be built cannot state a ceiling
      # either.
      class NumCtx
        FLAG = "--num-ctx"

        # @param backend [#provider, #model] the run, for the one question only
        #   it can answer: what is this model's trained maximum
        # @param value [Integer, nil] the raw flag; nil means unset, which is a
        #   real answer ("serve the model's own") and not the omission
        #   {Ceiling} refuses for a ceiling every turn needs
        def initialize(backend:, value:)
          @backend = backend
          @value = value
        end

        # @return [Integer, nil] the requested window, unchanged -- this
        #   validates a request against a ceiling, it does not clamp one
        # @raise [InvalidCeiling] on a non-positive value
        # @raise [UnservableWindow] when a trained maximum is known and the
        #   request is above it. Equal PASSES: the trained figure is exactly
        #   what the weights allow, and it is the number an operator reads off
        #   `/api/show` and types in.
        def tokens
          @value && refuse_above_trained(Ceiling.new(flag: FLAG, value: @value).tokens)
        end

        private

        def refuse_above_trained(requested)
          maximum = trained_maximum
          raise UnservableWindow, message(requested, maximum) if maximum && requested > maximum

          requested
        end

        # A THROWAWAY provider, like {WindowBook#book}'s and for its reason: a
        # trained maximum is a fact a SERVER reports, and there is no asking one
        # without a client. It costs one bounded round trip, and only for a run
        # that actually sets the flag -- `Ollama::Transport#model_details` rides
        # the same one-attempt, 2-second probe budget `/api/ps` does, so a
        # refusal cannot buy a hang.
        def trained_maximum
          @backend.provider.trained_context_tokens(@backend.model)
        rescue UnknownProvider, MissingAPIKey, URI::Error
          nil
        end

        def message(requested, maximum)
          "#{FLAG} #{requested} is above the model's trained maximum of #{maximum}; " \
            "no runner can serve a window larger than the weights were trained for"
        end
      end
    end
  end
end
