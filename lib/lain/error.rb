# frozen_string_literal: true

module Lain
  class Error < StandardError; end

  # A prompt refused WHOLE for not fitting the context it was sent to, carrying
  # the refuser's exact figures: `prompt_tokens` counted by the provider's own
  # tokenizer, `window_tokens` the context it actually loaded, and `source`
  # naming who said so.
  #
  # A duck rather than a class, because the refusal is raised inside each
  # provider's own error family -- `rescue Provider::Ollama::APIStatusError`
  # still means "the local chat backend failed" -- while the readers that act
  # on it ({Agent}, {Middleware::RequestBudget}) must not know which provider
  # spoke. No model evaluated the prompt and nothing was generated, which is
  # what lets an ask withdraw the turn that sent it.
  module WindowExceeded
    attr_reader :prompt_tokens, :window_tokens, :source

    def initialize(message = nil, prompt_tokens:, window_tokens:, source:, **rest)
      @prompt_tokens = Integer(prompt_tokens)
      @window_tokens = Integer(window_tokens)
      @source = -source.to_s
      super(message, **rest)
    end
  end
end
