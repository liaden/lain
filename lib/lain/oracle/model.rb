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

      # Exposed so a journaling wrapper ({Oracle::Recorded::Journaling}) records
      # WHICH model answered without being told twice. `usage` retains the LAST
      # call's cost, journalled by the same wrapper so an oracle call's spend is
      # visible in the Journal -- the bench's accounting reads there, never off
      # the tier.
      attr_reader :model

      # The question this tier answers under, exposed for {Heuristic#definition}'s
      # reason: a journaling wrapper is handed the definition off the tier it
      # wraps, so the pair cannot drift.
      attr_reader :definition

      # @param definition [Oracle::Definition] renders the question and validates
      #   the decoded reply -- both ends of the round trip, so this tier owns
      #   neither the prompt nor the schema
      # @param provider [Provider] the one round trip #ask spends; synchronous, so
      #   the Promise it returns is already resolved. Also asked whether it
      #   supports `:structured_output` -- see #structured_answer_format
      # @param model [String] which model answers, and the identity a journaling
      #   wrapper records off {#model}
      # @param max_tokens [Integer] the reply ceiling on every Request built here
      # @param decoder [#call] `Response -> answer attributes Hash`; the default
      #   parses the reply as JSON, and a structured-output decoder swaps in
      #   behind the same message
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
        Request.new(model: @model, max_tokens: @max_tokens, extra: structured_answer_format,
                    messages: [{ "role" => "user", "content" => @definition.render(inputs) }])
      end

      # A provider that can constrain its own decoding is handed the answer's
      # schema; one that cannot is asked plainly, and its request stays
      # byte-identical to what this tier sent before the marker existed -- the
      # point of the capability gate, since #extra reaching an encoder that reads
      # the same neutral key would move a prompt-cache prefix.
      #
      # Only the schema half of the marker is carried: the other half names a tool
      # for a tool-forcing backend to force, and an oracle sends no tools. The key
      # is neutral -- both encoders define this same String in separate leaf files
      # -- so naming Ollama's is a choice between identical constants, not a
      # dependency on ollama.
      def structured_answer_format
        return {} unless @provider.supports?(:structured_output)

        { Provider::Ollama::Encoding::STRUCTURED_OUTPUT_KEY =>
            { "schema" => @definition.schema.to_json_schema } }
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
