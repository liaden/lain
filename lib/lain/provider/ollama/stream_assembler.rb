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
          @frames = 0
          @terminated = false
          # The done line's four fields on one chain: nil is immutable, so it
          # cannot be aliased into a shared accumulator the way the Strings
          # above could be, and they are one fact -- what the terminal frame
          # said -- that goes whole or leaves a splice behind.
          @model = @done_reason = @prompt_eval_count = @eval_count = nil
          self
        end

        # What this attempt's stream failed to report, and how far it got before
        # it stopped -- or nil when it reported everything. #build_body writes
        # `"done" => true` whatever happened (it has to, to match the
        # non-streaming body), so this is the only place the difference
        # survives.
        #
        # ONE message rather than a reader per field, because the caller's whole
        # errand is to cut a single record: four reads across two objects is the
        # envy that put the ordering hazard below within reach in the first
        # place. The Hash is exactly the record's own field names, so the
        # emitter adds its join key and nothing else.
        #
        # `accumulated_bytes` is BYTES of message text -- content plus thinking
        # -- not characters: the figure is about how far the stream got on the
        # wire, and it travels beside `frames` so that "died on the first line"
        # and "died 2.8KB into an answer" read as the different diagnoses they
        # are. `tool_calls` is counted apart from it because a tool-call frame
        # carries no message text at all, and a stream severed with three calls
        # in flight must not render identically to three empty keepalives.
        #
        # @return [Hash{Symbol=>Object}, nil] frozen; `kind` is `:unterminated`
        #   when no terminal frame arrived, `:counts_absent` when one did but
        #   carried no token counts
        def truncation
          flush_trailing_line
          kind = unreported
          return nil if kind.nil?

          { kind:, model: @model, frames: @frames, tool_calls: @tool_calls.size,
            accumulated_bytes: @content.bytesize + @thinking.bytesize }.freeze
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
          flush_trailing_line
          build_body
        end

        private

        # Takes a final line that arrived without its `\n`, and IDEMPOTENTLY:
        # after the first call the buffer is empty and this is a no-op, which is
        # what lets #truncation and #result each drive it in either order.
        #
        # That is the fix for a real trap rather than tidiness. A stream cut
        # after its terminal frame but before the newline left that frame
        # sitting here, so a reading taken first answered "unterminated" and the
        # same reading after #result answered "fine" -- one object, one state,
        # two contradictory answers, no exception, and the wrong one fabricates
        # exactly the record this class exists to stop fabricating.
        #
        # The scan cursor goes back to zero with the bytes it indexed --
        # `@scanned` is an offset INTO the buffer, and leaving it past the end
        # of an emptied one would make a later #feed skip the newline it
        # points beyond.
        # THE SLICE GOES INTO A LOCAL AND THE CURSOR IS ZEROED BEFORE THE PARSE.
        # `ingest` raises on a torn line, so slicing straight into it empties
        # the buffer while the offset still indexes what used to be in it -- and
        # that stale offset then points PAST the newline of every line fed
        # afterwards, which are drained as one and handed to JSON.parse
        # together. Unreachable through the provider today, since a parse error
        # becomes an APIError and this object is dropped, but it is the same
        # latent class the reordering above removed and it is cheaper to close
        # than to remember.
        def flush_trailing_line
          return if @buffer.empty?

          line = @buffer.slice!(0, @buffer.bytesize)
          @scanned = 0
          ingest(line)
        end

        # Named for what is missing rather than for the stream's health, so the
        # nil arm reads as "nothing went unreported" instead of as a falsy
        # answer to a question nobody asked.
        def unreported
          return :unterminated unless @terminated
          return :counts_absent if @prompt_eval_count.nil? || @eval_count.nil?

          nil
        end

        # The newline search resumes where the last one stopped (`@scanned`):
        # rescanning from 0 on every feed is O(n^2) across a single huge line
        # delivered in many small chunks. Real NDJSON lines are short, but the
        # bound should not depend on the peer being polite.
        # THE CURSOR IS ZEROED BEFORE THE PARSE, NOT AFTER, and #flush_trailing_line
        # says why at length -- the two have the identical shape and would rot
        # apart if only one were fixed.
        def drain_complete_lines
          while (index = @buffer.index(NEWLINE, @scanned))
            line = @buffer.slice!(0, index + 1)
            @scanned = 0
            ingest(line)
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
          @frames += 1
          accumulate_message(data["message"] || {})
          @model = data["model"] unless data["model"].nil?
          capture_done(data) if data["done"]
        end

        def accumulate_message(message)
          @content << message["content"].to_s if message["content"]
          @thinking << message["thinking"].to_s if message["thinking"]
          Array(message["tool_calls"]).each { |call| @tool_calls << call }
        end

        # The flag is its own state rather than a test on @done_reason: a
        # terminal frame may legitimately carry a nil reason, and reading the
        # reason would then report a stream that DID finish as one that never
        # arrived -- the exact confusion #truncation exists to end.
        def capture_done(data)
          @terminated = true
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
