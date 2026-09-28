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

      # How many times one #ask puts the same question, at the SAME ceiling:
      # asked again with twice the room the same model went quiet twice, so a
      # second ask buys the nondeterminism and nothing else.
      ANSWER_ATTEMPTS = 2

      # Exposed so a journaling wrapper ({Oracle::Recorded::Journaling}) records
      # WHICH model answered without being told twice.
      attr_reader :model

      # The question this tier answers under, exposed for {Heuristic#definition}'s
      # reason: a journaling wrapper is handed the definition off the tier it
      # wraps, so the pair cannot drift.
      attr_reader :definition

      # @param definition [Oracle::Definition] renders the question and validates
      #   the decoded reply -- both ends of the round trip, so this tier owns
      #   neither the prompt nor the schema
      # @param provider [Provider] the round trips #ask spends, {ANSWER_ATTEMPTS}
      #   at most; synchronous, so the Promise it returns is already resolved.
      #   Also asked whether it supports `:structured_output` -- see
      #   #structured_answer_format
      # @param model [String] which model answers, and the identity a journaling
      #   wrapper records off {#model}
      # @param max_tokens [Integer] the reply ceiling on every Request built
      #   here, the retry included -- it asks again under the same one
      # @param decoder [#call] `Response -> answer attributes Hash`; the default
      #   parses the reply as JSON, and a structured-output decoder swaps in
      #   behind the same message
      # @param extra [Hash{String=>Object}] sampler options for every Request
      #   built here, already scoped by the caller to what this tier's provider
      #   and model may carry -- this object cannot tell a runner knob that keeps
      #   a shared runner loaded from one that reloads it. The answer's format
      #   and, on the native arm, `think` are merged OVER it and cannot be set
      #   from here
      def initialize(definition:, provider:, model:, max_tokens: DEFAULT_MAX_TOKENS, decoder: JsonDecoder.new,
                     extra: {})
        @definition = definition
        @provider = provider
        @model = model
        @max_tokens = max_tokens
        @decoder = decoder
        @extra = extra
        @usage = Usage.zero
      end

      def ask(inputs = {})
        @definition.answer(@decoder.call(answered(inputs)))
      end

      # What the LAST #ask spent, every round trip of it -- the figure
      # {Oracle::Recorded::Journaling} puts on the bench's record.
      #
      # @return [Hash] wire form; {} of zeros before the first ask
      def usage
        @usage.to_h
      end

      private

      # The spend accumulates in a LOCAL, assigned once: one {Oracle::Eager}
      # fires a task per tool result over ONE of these, and an accumulator on the
      # instance would put an overlapping ask's tokens on this ask's record.
      def answered(inputs)
        spend = Usage.zero
        replies = (1..ANSWER_ATTEMPTS).lazy.map do
          @provider.complete(request_for(inputs)).tap { |reply| spend += reply.usage }
        end
        answer = replies.reject { |reply| said_nothing?(reply) }.first
        @usage = spend
        answer || raise(UndecodableAnswer, "oracle reply was empty: nothing came back in #{ANSWER_ATTEMPTS} asks")
      end

      # Where a thinking model goes quiet: all reasoning and no answer is a
      # finished turn on the wire, not an empty one. Truncation needs no arm of
      # its own -- cut off having said nothing it is retried like any silence,
      # cut off mid-answer it carries text and reaches the decoder's raise.
      def said_nothing?(reply) = Blankness.blank?(reply.text)

      def request_for(inputs)
        Request.new(model: @model, max_tokens: @max_tokens,
                    extra: @extra.merge(structured_answer_format, thinking_off),
                    messages: [{ "role" => "user", "content" => @definition.render(inputs) }])
      end

      # A provider that can constrain its own decoding is handed the answer's
      # schema, merged OVER the caller's options so none of them can unset the
      # format the decoder depends on; one that cannot is asked plainly, and its
      # request stays byte-identical to what this tier sent before the marker
      # existed -- the point of the capability gate, since #extra reaching an
      # encoder that reads the same neutral key would move a prompt-cache prefix.
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

      # An oracle wants an ANSWER, never a monologue: the default local model
      # spends 3.9k-8k characters reasoning, the whole of a 1024-token ceiling
      # before the JSON starts -- an empty reply every call, on two builds.
      #
      # The gate STANDS IN for "this wire has a `think` field", which no provider
      # message asks; {Provider::ModelCapabilities} answers the narrower "does
      # THIS model think" and is deliberately not asked, its UNKNOWN being a fact
      # about the probe rather than about the model.
      def thinking_off
        return {} unless @provider.supports?(:structured_output)

        { Provider::Ollama::Encoding::THINK_KEY => false }
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
