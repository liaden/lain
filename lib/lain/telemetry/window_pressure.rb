# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Both figures are the provider's own, so both are required: a record
      # that cannot say how big the prompt was or how big the context is claims
      # an overflow nobody can check.
      class WindowPressure < Declarative::Carrier
        attribute :kind
        attribute :source
        attribute :request_digest
        attribute :prompt_tokens
        attribute :window_tokens
        validates :kind, inclusion: { in: %i[over_window], message: "must be over_window, got %<value>s" }
        validates :source, presence: { message: "must name the provider that refused the prompt, got nil" }
        validates :request_digest, presence: { message: "must name the request that was refused, got nil" }
        validates :prompt_tokens,
                  numericality: { only_integer: true, greater_than: 0,
                                  message: "must be the provider's positive prompt count, got %<value>s" }
        validates :window_tokens,
                  numericality: { only_integer: true, greater_than: 0,
                                  message: "must be the positive context the provider loaded, got %<value>s" }
      end
    end

    # A prompt its provider refused whole for not fitting the context. The
    # presence of the record is the signal: a session whose prompts all fit
    # journals none.
    #
    # Every figure is the REFUSER's, never an estimate: `prompt_tokens` counted
    # by its own tokenizer, `window_tokens` the context it actually loaded --
    # which can differ from the window book's, since ollama reloads a runner
    # at the request's `num_ctx` -- and `source` names who said so.
    # `request_digest` joins it onto the `request_sent` that carried the
    # prompt. `kind` is a closed set of one, kept so a reader discriminates on a
    # tag rather than on shape. `stands_on` is the turn the count is believed on
    # ({Event.stands_on}, named by the Agent as it called the model), so a live
    # view tags the reading as the Agent does instead of inferring it; nil is
    # the empty chain, a value, which is why the keyword has no default.
    #
    # `spawn` names the spawned child whose prompt this was, and is nil for the
    # run's own ask. Every other figure is measured against the refuser's own
    # window on the chain that rendered the prompt, so a reader that folds a
    # child's record into the run's reading tags it with a window and a chain
    # this run never rendered -- which is why the attribution rides the record
    # rather than being inferred from where it landed.
    #
    # It rides the record journal, which is the tee in a cockpit, so the
    # {StatusFeed} takes the same reading the {Agent} does.
    WindowPressure = Data.define(:kind, :source, :model, :request_digest, :prompt_tokens, :window_tokens,
                                 :stands_on, :spawn) do
      include Journalable

      def initialize(kind:, source:, request_digest:, prompt_tokens:, window_tokens:, stands_on:, model: nil,
                     spawn: nil)
        kind = kind&.to_sym
        Carriers::WindowPressure.check!(kind:, source:, request_digest:, prompt_tokens:, window_tokens:)

        super(kind:, source: -source.to_s, model: model && -model.to_s, request_digest: -request_digest.to_s,
              prompt_tokens: Integer(prompt_tokens), window_tokens: Integer(window_tokens),
              stands_on: stands_on && -stands_on.to_s, spawn: spawn && -spawn.to_s)
      end
    end
  end
end
