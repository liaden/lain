# frozen_string_literal: true

require "json"

module Lain
  class Provider
    class Ollama < Provider
      # Reassembles Ollama's NDJSON `/api/chat` stream into the SAME body Hash the
      # non-streaming endpoint returns, so {Ollama#complete} decodes both paths
      # through one #build_response -- path parity by construction.
      #
      # Streamed `/api/chat` is `application/x-ndjson`: one complete JSON object
      # per `\n`-terminated line, `message.content` (and `message.thinking`)
      # arriving in fragments, `tool_calls` on their own line(s), the last line
      # carrying `done: true` + `done_reason` + the token counts. There is no SSE
      # framing here -- no `data:` prefix, no `[DONE]` sentinel -- so the vendored
      # `EventStreamParser` does not apply; this is the NDJSON line-reader it is
      # replaced by.
      #
      # == Why byte buffering, not String#each_line on the chunk
      #
      # A TCP read boundary can split a line -- or a multibyte UTF-8 codepoint --
      # across two chunks (the `input_json_delta` lesson transposed to whole
      # lines), and a cassette never reproduces that split. So bytes accumulate in
      # a BINARY buffer and a line is only cut, re-encoded UTF-8, and parsed once
      # its terminating `\n` has arrived. This is safe mid-codepoint because
      # `\n` (0x0A) never appears inside a multibyte sequence -- UTF-8 is self-
      # synchronizing, every continuation byte is >= 0x80 -- so splitting on the
      # newline byte can never bisect a character.
      class StreamAssembler
        NEWLINE = "\n".b

        def initialize
          @buffer = +"".b
          @scanned = 0
          @content = +""
          @thinking = +""
          @tool_calls = []
          @model = nil
          @done_reason = nil
          @prompt_eval_count = nil
          @eval_count = nil
        end

        # @param chunk [String] raw bytes off the wire, any boundary
        def feed(chunk)
          @buffer << chunk.to_s.b
          drain_complete_lines
          self
        end

        # @return [Hash] the non-streaming `/api/chat` body shape, ready for
        #   {Ollama#build_response}. A trailing line with no newline (a stream cut
        #   without its final `\n`) is flushed here.
        def result
          ingest(@buffer.slice!(0, @buffer.bytesize)) unless @buffer.empty?
          build_body
        end

        private

        # The newline search resumes where the last one stopped (`@scanned`):
        # rescanning from 0 on every feed is O(n^2) across a single huge line
        # delivered in many small chunks. Real NDJSON lines are short, but the
        # bound should not depend on the peer being polite.
        def drain_complete_lines
          while (index = @buffer.index(NEWLINE, @scanned))
            ingest(@buffer.slice!(0, index + 1))
            @scanned = 0
          end
          @scanned = @buffer.bytesize
        end

        # `::Encoding` is qualified: the sibling {Ollama::Encoding} mixin shadows
        # the top-level constant by lexical lookup from inside this class.
        def ingest(line)
          text = line.force_encoding(::Encoding::UTF_8).strip
          add(JSON.parse(text)) unless text.empty?
        end

        # Accumulate one parsed NDJSON object. Content and thinking fragments
        # concatenate in arrival order; tool_calls append (they carry their own
        # parsed arguments, belief (b)); the done line contributes the reason and
        # counts.
        def add(data)
          accumulate_message(data["message"] || {})
          @model = data["model"] unless data["model"].nil?
          capture_done(data) if data["done"]
        end

        def accumulate_message(message)
          @content << message["content"].to_s if message["content"]
          @thinking << message["thinking"].to_s if message["thinking"]
          Array(message["tool_calls"]).each { |call| @tool_calls << call }
        end

        def capture_done(data)
          @done_reason = data["done_reason"]
          @prompt_eval_count = data["prompt_eval_count"]
          @eval_count = data["eval_count"]
        end

        # Rebuilds the message field-by-field so the reassembled body matches the
        # non-streaming one key-for-key: thinking/tool_calls appear only when the
        # stream actually carried them, exactly as the single-body endpoint omits
        # empty fields.
        def build_body
          message = { "role" => "assistant", "content" => @content }
          message["thinking"] = @thinking unless @thinking.empty?
          message["tool_calls"] = @tool_calls unless @tool_calls.empty?
          { "model" => @model, "message" => message, "done" => true, "done_reason" => @done_reason,
            "prompt_eval_count" => @prompt_eval_count, "eval_count" => @eval_count }
        end
      end
    end
  end
end
