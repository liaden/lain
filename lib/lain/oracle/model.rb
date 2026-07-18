# frozen_string_literal: true

require "json"

module Lain
  module Oracle
    # A model reply that could not be decoded into answer attributes. Loud, like
    # {InvalidAnswer}: a garbled reply is a failure to surface, not to default.
    class UndecodableAnswer < Error; end

    # The model-backed tier: render the question, complete it against a provider,
    # decode the reply, and validate it through the definition's schema. Returns
    # the same {Promise} the heuristic tier does. The provider round trip is
    # synchronous and the Promise is ALWAYS pre-resolved before #ask returns, so
    # awaiting it never parks a fiber (unlike ask_human's promise, which can be
    # pending and is resolved later by #reply). Overlapping N model calls is the
    # CALLER's job -- a task per #ask; `ask(...).await` in a loop serializes.
    class Model
      DEFAULT_MAX_TOKENS = 1024

      # @param decoder [#call] `Response -> answer attributes Hash`; the default
      #   parses the reply as JSON. A stronger structured-output decoder (T1)
      #   swaps in behind the same message without this tier changing shape.
      # `model` is exposed so a journaling wrapper ({Oracle::Recorded::Journaling})
      # records WHICH model answered without being told twice; `usage` retains the
      # LAST call's token cost, which the same wrapper journals so an oracle
      # model call's spend is visible in the Journal (the bench's cost accounting
      # reads there, never off the tier). Held as the wire Hash, the shape
      # {Telemetry::TurnUsage} already keeps.
      attr_reader :model

      def initialize(definition:, provider:, model:, max_tokens: DEFAULT_MAX_TOKENS, decoder: JsonDecoder.new)
        @definition = definition
        @provider = provider
        @model = model
        @max_tokens = max_tokens
        @decoder = decoder
        @usage = Usage.zero
      end

      def ask(inputs = {})
        response = @provider.complete(request_for(inputs))
        @usage = response.usage
        @definition.answer(@decoder.call(response))
      end

      # @return [Hash] the last call's token usage in wire form ({} of zeros
      #   before the first #ask)
      def usage
        @usage.to_h
      end

      private

      def request_for(inputs)
        Request.new(model: @model, max_tokens: @max_tokens,
                    messages: [{ "role" => "user", "content" => @definition.render(inputs) }])
      end

      # The default decoder: the reply is a JSON object of the answer's fields.
      class JsonDecoder
        def call(response)
          JSON.parse(response.text)
        rescue JSON::ParserError => e
          raise UndecodableAnswer, "oracle reply was not decodable JSON: #{e.message}"
        end
      end
    end
  end
end
