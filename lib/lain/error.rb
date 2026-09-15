# frozen_string_literal: true

module Lain
  class Error < StandardError; end

  # A refusal raised before the command refusing changed anything. Its message
  # names its own remedy, so a caller never sends a human on to resume work
  # that never started -- the epic driver reads it to tell a refused landing
  # from one whose merge broke part-way.
  #
  # Declared on the refusal class itself, never listed by its readers: a list
  # misses the class added after it.
  module RefusedBeforeActing; end

  # The records a decision rests on cannot be read. Every decision over the
  # same journals fails alike, so a loop over many subjects stops at the first
  # rather than blaming the damage on each subject in turn.
  module JournalUnreadable; end

  # Whether the {Agent} took back the prompt that met this error. Only the
  # Agent knows, and only after the error was raised: the same refusal after a
  # tool round in the same ask leaves the prompt where it was. Mutable, because
  # it is the raised object itself the readers downstream of the Agent see --
  # so an error object raised twice keeps the mark from its first raise.
  module Withdrawal
    def withdrawn! = (@withdrawn = true) && self

    def withdrawn? = @withdrawn == true
  end

  # A prompt refused WHOLE for not fitting the context it was sent to, carrying
  # the refuser's exact figures: `prompt_tokens` counted by the provider's own
  # tokenizer, `window_tokens` the context it actually loaded, and `source`
  # naming who said so. `model` is the refused request's, when the raiser could
  # see the request; a provider's own error cannot, and leaves it nil.
  #
  # A duck rather than a class, because the refusal is raised inside each
  # provider's own error family -- `rescue Provider::Ollama::APIStatusError`
  # still means "the local chat backend failed" -- while the readers that act
  # on it ({Agent}, {Middleware::RequestBudget}) must not know which provider
  # spoke. No model evaluated the prompt and nothing was generated, which is
  # what lets an ask withdraw the turn that sent it.
  module WindowExceeded
    include Withdrawal

    attr_reader :prompt_tokens, :window_tokens, :source, :model

    def initialize(message = nil, prompt_tokens:, window_tokens:, source:, model: nil, **rest)
      @prompt_tokens = Integer(prompt_tokens)
      @window_tokens = Integer(window_tokens)
      @source = -source.to_s
      @model = model && -model.to_s
      super(message, **rest)
    end

    # The context the refuser loaded is a measured window, so a book that
    # adopts measured windows adopts it -- for the refused request's model when
    # this error names one, and for the book's own model otherwise.
    #
    # @param book [#vouch]
    def vouch(book) = model.nil? ? book.vouch(window_tokens) : book.vouch(window_tokens, model:)
  end

  # A provider failure raised before any request byte left the process, on
  # every attempt the round trip made. Like {WindowExceeded}, no model saw the
  # prompt, so an ask may withdraw it.
  module PreWire
    include Withdrawal
  end

  # The cause a stop-this-ask interrupt carries, which is what tells a stopped
  # ask apart from a Ctrl-C: both unwind through `Async::Stop`.
  class Stopped < Error; end
end
