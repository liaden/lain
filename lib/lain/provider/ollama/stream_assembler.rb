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
      # per `\n`-terminated line, content and thinking arriving in fragments,
      # `tool_calls` on their own lines, the last line carrying `done: true` +
      # `done_reason` + the token counts. There is no SSE framing -- no `data:`
      # prefix, no `[DONE]` sentinel -- so the vendored `EventStreamParser` does
      # not apply.
      #
      # == Why byte buffering, not String#each_line on the chunk
      #
      # A TCP read boundary can split a line -- or a multibyte UTF-8 codepoint
      # -- across two chunks, and a cassette never reproduces that split. So
      # bytes accumulate in a BINARY buffer and a line is only cut, re-encoded
      # UTF-8, and parsed once its terminating `\n` has arrived. Safe
      # mid-codepoint because `\n` (0x0A) never appears inside a multibyte
      # sequence -- UTF-8 is self-synchronizing, every continuation byte is
      # >= 0x80 -- so splitting on the newline byte cannot bisect a character.
      #
      # == Why the discard is DRIVEN, not detected
      #
      # This accumulates across every #feed and cannot notice that the
      # connection under it was replaced. SSE carries a `message_start` an
      # assembler can re-sync on; NDJSON carries no equivalent, so a retried
      # stream is indistinguishable from a continuation of the attempt it
      # replaced -- which is how a severed attempt plus a clean retry returned
      # both attempts' text concatenated under a done_reason of "stop". Nothing
      # in the protocol can fix that, so {Ollama#stream_body} registers #reset
      # on the round trip's {RetryTap::Attempt}.
      #
      # The alternative was rebinding the closure, which needs no #reset and
      # passes the same tests. #reset was chosen because the discard is then a
      # PROPERTY OF THIS CLASS, unit-testable on its own -- that a discard
      # leaves an assembler ivar-for-ivar identical to a fresh one is an
      # assertion, that a local was rebound is not -- and because rebinding
      # leans on the block closing over the same local the chunk callback reads.
      # The cost is the rule below.
      #
      # ⚠️ EVERY piece of state added to this class must be cleared in #reset.
      # The constructor delegates to it precisely so there is one list rather
      # than two that can drift, but a new `@foo` assigned anywhere else would
      # survive a retry and become the next splice.
      class StreamAssembler
        # `.b` returns a NEW, unfrozen String even under
        # `frozen_string_literal: true`, so this needs the explicit freeze that
        # a plain literal would have got for free.
        NEWLINE = "\n".b.freeze

        # Delegates to the public #reset so the state list exists ONCE. That
        # does mean the constructor calls an overridable method -- harmless
        # while nothing subclasses this, and noted rather than defended against,
        # since the alternative reintroduces the two-lists drift.
        def initialize = reset

        # Leaves this assembler as it was BUILT, not merely emptied. The
        # metadata goes too, not just the prose: an attempt that reached its
        # `done` line before the connection died would otherwise report ITS
        # done_reason and token counts as the survivor's.
        #
        # Called once per RETRY, so three retries call it three times: assigning
        # fresh literals is why that is the same operation every time. And it
        # MUST NOT RAISE -- {RetryTap#retry_block} abandons before it journals,
        # so an exception here would lose that attempt's
        # {Telemetry::ProviderRetry} and replace the transport error
        # faraday-retry was carrying. Literal assignments have no failure mode;
        # keep it that way.
        def reset
          @buffer = +"".b
          @scanned = 0
          @content = +""
          @thinking = +""
          @tool_calls = []
          @model = nil
          @done_reason = nil
          @prompt_eval_count = nil
          @eval_count = nil
          self
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

        # Content and thinking fragments concatenate in arrival order;
        # tool_calls append, carrying their own already-parsed arguments.
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

        # Field-by-field so the reassembled body matches the non-streaming one
        # key-for-key: thinking and tool_calls appear only when the stream
        # carried them, exactly as the single-body endpoint omits empty
        # fields.
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
