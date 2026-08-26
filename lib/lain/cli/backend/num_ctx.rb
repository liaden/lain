# frozen_string_literal: true

module Lain
  module CLI
    class Backend
      # A `--num-ctx` larger than any runner could ever serve. Refused at
      # construction because the flag is well-formed, so nothing downstream
      # refuses it and the number is silently adopted as the run's whole
      # denominator instead. Measured: `--num-ctx 999999` on a model trained to
      # 262,144 journaled `window=999999 provenance="probed"` while ollama
      # served 262,144.
      class UnservableWindow < Error; end

      # An optional per-request context length, refused two ways, in the flag's
      # own name. Its own object because looking a ceiling up off a live server
      # is not something a flag bag should do.
      #
      # The two passes are ordered, and the order is load-bearing:
      #
      # 1. **Non-positive is refused by {Ceiling}**, keeping the positivity rule
      #    for every token knob in one place. First, because `--num-ctx 0` is a
      #    mistake whatever the model was trained to -- reordering would make
      #    the error an operator sees depend on whether a server was up.
      # 2. **Above the trained maximum is refused here.** An operator's
      #    `--num-ctx` is a REQUEST, and the trained maximum is the one number
      #    it can be checked against before any runner exists.
      #
      # The trained maximum is a CEILING, NEVER A DENOMINATOR, which is why
      # {Provider#trained_context_tokens} is a second accessor: the trained
      # figure is 262,144 for qwen3-coder:30b while the runner serves 32,768, so
      # dividing occupancy by it under-reports 8x and `:approaching_window`
      # never fires -- the failure `context_window.rb` ranks as worse than the
      # crash the conservative fallback replaces. Nothing here reaches
      # {ContextWindow::WindowResolution}.
      #
      # Only ollama publishes a trained maximum, and only while running, so nil
      # is a real answer and the refusal fires just where a maximum is known AND
      # exceeded. Every provider-resolution failure is deferred to
      # {Backend#provider}'s real callers, as {WindowBook#book} defers them: a
      # provider that cannot be built cannot state a ceiling either.
      class NumCtx
        FLAG = "--num-ctx"

        # @param backend [#provider, #model] the run, for the one question only
        #   it can answer: what is this model's trained maximum
        # @param value [Integer, nil] the raw flag; nil means unset, a real
        #   answer ("serve the model's own") and not the omission {Ceiling}
        #   refuses for a ceiling every turn needs
        def initialize(backend:, value:)
          @backend = backend
          @value = value
        end

        # @return [Integer, nil] the requested window, unchanged -- this
        #   validates a request against a ceiling, it does not clamp one
        # @raise [InvalidCeiling] on a non-positive value
        # @raise [UnservableWindow] when a trained maximum is known and the
        #   request is above it. Equal PASSES: the trained figure is what the
        #   weights allow, and it is the number an operator reads off
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
        # without a client. `Ollama::Transport#model_details` rides the same
        # one-attempt, 2-second probe budget `/api/ps` does, so a refusal cannot
        # buy a hang.
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
