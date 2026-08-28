# frozen_string_literal: true

require "json"

# Whether the stream ever TERMINATED, and the record that says so.
#
# `#build_body` writes `"done" => true` unconditionally, because the
# non-streaming body it has to match always carries one -- so a connection that
# died mid-answer reassembles into a body byte-identical in shape to a complete
# one, decoding to a nil `done_reason` and all-zero usage with the prose intact.
# Nothing above the provider can tell that from a model that genuinely stopped
# with no counts to report, which is how the failure was seen once and lost.
#
# This file pins the two halves of the fix: the assembler REPORTS what it saw in
# ONE message (it takes no arguments and holds no channel, so it cannot emit),
# and {Lain::Provider::Ollama#stream_body} -- which holds the journal and knows
# the request -- is where the record is cut and the join key added.
#
# The reassembly properties themselves (chunk-boundary immunity, path parity,
# the discard a retry drives) live in `spec/lain/provider/ollama_streaming_spec.rb`
# alongside the provider seam that exercises them.
RSpec.describe Lain::Provider::Ollama::StreamAssembler do
  def content_line(text)
    { "model" => "qwen3:4b", "message" => { "role" => "assistant", "content" => text }, "done" => false }
  end

  def tool_call_line(name)
    { "model" => "qwen3:4b",
      "message" => { "role" => "assistant", "content" => "",
                     "tool_calls" => [{ "function" => { "name" => name, "arguments" => { "text" => "hi" } } }] },
      "done" => false }
  end

  def done_line(**overrides)
    { "model" => "qwen3:4b", "message" => { "role" => "assistant", "content" => "" },
      "done" => true, "done_reason" => "stop", "prompt_eval_count" => 11, "eval_count" => 7 }.merge(overrides)
  end

  def ndjson(lines) = "#{lines.map { |line| JSON.generate(line) }.join("\n")}\n"

  # "café" puts a multibyte codepoint in the prose, so a byte count that was
  # really a character count is visible rather than plausible.
  def content_lines = [content_line("Hel"), content_line("lo, café")]

  def fed(lines)
    described_class.new.tap { |assembler| assembler.feed(ndjson(lines)) }
  end

  describe "#truncation, the reading a record is cut from" do
    it "answers nothing for a stream whose terminal frame carried its counts" do
      expect(fed(content_lines + [done_line]).truncation).to be_nil
    end

    it "answers :unterminated when no terminal frame ever arrived" do
      expect(fed(content_lines).truncation).to include(kind: :unterminated)
    end

    it "answers :counts_absent when a terminal frame arrived with no token counts" do
      expect(fed(content_lines + [done_line(prompt_eval_count: nil, eval_count: nil)]).truncation)
        .to include(kind: :counts_absent)
    end

    # ONE message, so a caller building a record makes one call to one object
    # rather than reading four fields off two -- and so the model travels with
    # the counts instead of being re-derived from the reassembled body.
    it "hands over the whole reading, model included, as one frozen answer" do
      reading = fed(content_lines).truncation

      expect(reading).to eq(kind: :unterminated, model: "qwen3:4b", frames: 2,
                            accumulated_bytes: "Hello, café".bytesize, tool_calls: 0)
      expect(reading).to be_frozen
    end

    it "counts thinking bytes too, since they are prose the truncation cost the caller" do
      assembler = described_class.new
      assembler.feed(ndjson([{ "message" => { "role" => "assistant", "thinking" => "hm" }, "done" => false }]))

      expect(assembler.truncation).to include(accumulated_bytes: 2)
    end

    # The most dangerous truncation shape. A tool-call frame carries no message
    # text, so a byte count alone renders "died having emitted three tool calls"
    # -- with the caller possibly holding a half-formed one -- identically to
    # three empty keepalives. The count is separate rather than folded into the
    # bytes because the actionable fact is HOW MANY calls were in flight, not
    # how much serialized JSON they came to.
    it "counts severed tool calls, so they are not read as a stream that delivered nothing" do
      expect(fed([tool_call_line("echo"), tool_call_line("bash"), tool_call_line("grep")]).truncation)
        .to include(frames: 3, accumulated_bytes: 0, tool_calls: 3)
    end

    # The trap the docstring used to be the only thing holding: a terminal frame
    # that arrived without its trailing newline sits in the buffer until it is
    # flushed, so asking first used to report :unterminated and asking after
    # #result reported nothing -- same object, same state, two contradictory
    # answers and no exception. So the reading drives the flush itself.
    it "answers the same before and after #result when the terminal frame lacked its newline" do
      assembler = described_class.new
      assembler.feed(ndjson(content_lines) + JSON.generate(done_line))
      before = assembler.truncation
      assembler.result

      expect(before).to be_nil
      expect(assembler.truncation).to be_nil
    end

    it "is idempotent, so asking twice cannot double-count the frames it flushed" do
      assembler = described_class.new
      assembler.feed(ndjson(content_lines).chomp)

      expect(assembler.truncation).to eq(assembler.truncation)
      expect(assembler.truncation).to include(frames: 2)
    end

    it "leaves #result the same answer whichever was asked first" do
      early = described_class.new.tap { |a| a.feed(ndjson(content_lines).chomp) }
      early.truncation

      expect(early.result).to eq(fed(content_lines).result)
    end

    # The same latent shape one path over, and the reason the slice goes into a
    # local before the cursor is zeroed: `ingest` raises on a torn line, so a
    # slice-then-ingest order empties the buffer while the offset still indexes
    # what used to be in it. The stale offset then points PAST the newline of
    # every line fed afterwards, and they are handed to JSON.parse as one.
    #
    # Unreachable through the provider today -- a parse error becomes an
    # APIError and the assembler is dropped -- so this is hardening. The torn
    # line is long on purpose: a short one leaves an offset that happens to land
    # before the next newline, which hides the skip.
    describe "a torn line, and the cursor it must not leave behind" do
      it "keeps draining the lines that follow one torn at the flush" do
        assembler = described_class.new
        assembler.feed("{#{"x" * 200}")
        expect { assembler.result }.to raise_error(JSON::ParserError)
        assembler.feed(ndjson(content_lines + [done_line]))

        expect(assembler.result["message"]["content"]).to eq("Hello, café")
      end

      it "keeps draining the lines that follow one torn mid-buffer" do
        assembler = described_class.new
        assembler.feed("{#{"x" * 200}")
        expect { assembler.feed("}\n#{JSON.generate(content_line("Hel"))}\n") }
          .to raise_error(JSON::ParserError)
        assembler.feed(ndjson([content_line("lo"), done_line]))

        expect(assembler.result["message"]["content"]).to eq("Hello")
      end
    end

    # The state list has exactly one home (#reset), and a counter that survived
    # a discard would report the abandoned attempt's frames as the survivor's --
    # the same splice the prose accumulators already guard against.
    it "is left as a fresh assembler's by #reset, counters and terminal flag alike" do
      assembler = fed(content_lines + [done_line])
      assembler.reset

      expect(assembler.truncation).to eq(kind: :unterminated, model: nil, frames: 0,
                                         accumulated_bytes: 0, tool_calls: 0)
    end

    # {Lain::Provider::Ollama::RetryTap#retry_block} abandons the attempt BEFORE
    # it journals, so an exception raised here would lose that attempt's
    # ProviderRetry and replace the transport error faraday-retry was carrying.
    it "resets without raising however many discards a round trip drives" do
      assembler = fed(content_lines + [done_line])

      expect { 3.times { assembler.reset } }.not_to raise_error
    end
  end

  # The emission belongs to the provider, which holds the journal and knows the
  # request. The assembler is deliberately voiceless and request-ignorant.
  describe Lain::Provider::Ollama, "#stream_body" do
    def request
      Lain::Request.new(model: "qwen3:4b", max_tokens: 64,
                        messages: [{ role: "user", content: "hi" }], stream: true)
    end

    # `attempt:` and `frame:` are DECLARED so a provider that stopped threading
    # them fails loudly here rather than handing them over as a positional Hash
    # of headers -- see `ollama_spec.rb`'s #transport_sync for the full note.
    # rubocop:disable Lint/UnusedBlockArgument
    def stream_transport(chunks, abandon_after: nil)
      Class.new do
        define_method(:stream) do |_payload, _headers = {}, attempt: nil, frame: nil, &block|
          chunks.each_with_index do |chunk, index|
            block.call(chunk)
            attempt&.abandon if index == abandon_after
          end
        end
      end.new
    end
    # rubocop:enable Lint/UnusedBlockArgument

    def journaled(chunks, abandon_after: nil)
      io = StringIO.new
      response = described_class.new(transport: stream_transport(chunks, abandon_after:),
                                     journal: Lain::Journal.new(io:)).complete(request)
      [response, io]
    end

    it "journals a truncated_stream naming the frames and the bytes when no terminal frame arrived" do
      _response, io = journaled([ndjson(content_lines)])

      expect(io).to include_journal_record("truncated_stream", kind: "unterminated", model: "qwen3:4b",
                                                               frames: 2, tool_calls: 0,
                                                               accumulated_bytes: "Hello, café".bytesize)
    end

    # Without this the record cannot be joined to anything. One Provider is
    # constructed once and reused -- the chat tier and the summarizer tier share
    # it for a whole session -- so several round trips interleave on one channel
    # and `model` plus adjacency cannot say which stream died.
    it "names the round trip it describes, so the record joins onto its RequestSent" do
      _response, io = journaled([ndjson(content_lines)])

      expect(io).to include_journal_record("truncated_stream", request_digest: request.digest)
    end

    # The whole reason this card records rather than repairs: the original
    # observation was a CONTENT-BEARING turn, and a fix that turned a silent
    # accounting bug into a lost answer would be the worse defect.
    it "still hands the caller the content the frames delivered" do
      response, = journaled([ndjson(content_lines)])

      expect(response.content).to eq([{ "type" => "text", "text" => "Hello, café" }])
    end

    it "journals nothing for a stream that terminated with its token counts" do
      _response, io = journaled([ndjson(content_lines + [done_line])])

      expect(io.string).to be_empty
    end

    it "journals a truncated_stream naming the absent counts when the terminal frame carried none" do
      _response, io = journaled([ndjson(content_lines + [done_line(prompt_eval_count: nil, eval_count: nil)])])

      expect(io).to include_journal_record("truncated_stream", kind: "counts_absent", frames: 3)
    end

    # A mid-stream sever is cleanly RETRIED, so the abandoned attempt is not the
    # turn -- a record for it is noise pointing at a stream nobody was served.
    # The reset that discards its prose discards its counters with it.
    it "says nothing about a severed attempt that a clean retry replaced" do
      _response, io = journaled([ndjson(content_lines), ndjson(content_lines + [done_line])], abandon_after: 0)

      expect(io.string).to be_empty
    end

    # The mirror image, and the one that proves the scoping is to the RETURNED
    # attempt rather than to "any attempt that finished": a complete attempt
    # abandoned mid-round-trip cannot vouch for the truncated one that replaced it.
    it "records the attempt actually returned, even when a discarded one had terminated" do
      _response, io = journaled([ndjson(content_lines + [done_line]), ndjson(content_lines)], abandon_after: 0)

      expect(io).to include_journal_record("truncated_stream", kind: "unterminated", frames: 2)
    end

    # The Null journal is the default, so nothing above the provider ever writes
    # `if journal` -- a bare construction records nowhere and still decodes.
    it "decodes a truncated stream over the default Null journal with no guard" do
      response = described_class.new(transport: stream_transport([ndjson(content_lines)])).complete(request)

      expect(response.content).to eq([{ "type" => "text", "text" => "Hello, café" }])
    end
  end
end
