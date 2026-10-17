# frozen_string_literal: true

require "json"
require "event_stream_parser"

module Lain
  class Provider
    # Rebuilds the {Lain::Response} a response-log frame recorded, with the
    # decoder of the provider that wrote the frame. A frame holds the EXACT bytes
    # a provider teed off its wire, and its header names that wire, so this is
    # the live path replayed over recorded bytes rather than a second parser:
    # each decoder below is the assembler and the `#build_response` the live
    # provider drives. An ollama frame read as SSE parses to nothing at all,
    # which is how a crashed ollama session once recovered as an empty turn.
    #
    # Feeding a whole recorded blob to an assembler in one call is sound: both
    # assemblers line-buffer internally, so one chunk and many are the same.
    #
    # A frame the Reader marks complete cannot hold an in-band SSE error event:
    # {Provider::HTTP::Streaming::ErrorHandling} raises on one before the
    # transport closes the frame complete. The filter in {AnthropicStream} is
    # defensive, not a branch a complete frame reaches.
    module Reassembly
      class Unknown < Lain::Error; end

      # Shared by the two anthropic wires: the live provider's own decoder.
      class AnthropicBody
        include AnthropicWire

        def call(text, _ceiling) = build_response(assembled(text))
      end

      # Raw SSE lines, as {Provider::Anthropic::Transport} teed them.
      class AnthropicStream < AnthropicBody
        def assembled(text)
          assembler = Anthropic::StreamAssembler.new
          events(text).each { |event| assembler.add(event) }
          assembler.result
        end

        private

        def events(text)
          collected = []
          EventStreamParser::Parser.new.feed(text) { |type, data| collected << [type.to_s, data] }
          collected.reject { |type, data| type == "error" || data == "[DONE]" }
                   .map { |_type, data| JSON.parse(data) }
        end
      end

      # The body of a non-streaming request.
      class AnthropicSync < AnthropicBody
        def assembled(text) = Anthropic::StreamAssembler::Assembled.from_body(JSON.parse(text))
      end

      # Shared by the two ollama wires. A reassembly writes no record: the live
      # call already journaled whatever its decode found, and a replay has no
      # session record of its own to write to.
      class OllamaBody
        include Ollama::Decoding

        def call(text, ceiling) = build_response(body(text), ceiling, Channel::Null::INSTANCE)
      end

      # NDJSON lines, as the ollama transport teed them.
      class OllamaStream < OllamaBody
        def body(text) = Ollama::StreamAssembler.new.feed(text).result
      end

      # The body of a non-streaming request.
      class OllamaSync < OllamaBody
        def body(text) = JSON.parse(text)
      end

      DECODERS = {
        "anthropic-sse" => AnthropicStream.new.freeze,
        "anthropic-json" => AnthropicSync.new.freeze,
        "ollama-ndjson" => OllamaStream.new.freeze,
        "ollama-json" => OllamaSync.new.freeze
      }.freeze

      # @param entry [#bytes, #wire] a {ResponseWal::Entry}; Entry#bytes is
      #   ASCII-8BIT (binread), so it is read as UTF-8 here, before any parse
      # @param ceiling [Integer, nil] the `max_tokens` the request sent, which
      #   tells a spent cap from a full window; nil when it is not known
      # @return [Lain::Response]
      # @raise [Unknown] for a wire with no decoder, or none recorded
      def self.call(entry, ceiling:)
        decoder(entry.wire).call(entry.bytes.dup.force_encoding(Encoding::UTF_8), ceiling)
      end

      def self.decoder(wire)
        raise Unknown, "no wire was recorded for this frame" if wire.nil?

        DECODERS.fetch(wire) { raise Unknown, "no reassembly for wire #{wire.inspect}" }
      end
      private_class_method :decoder
    end
  end
end
