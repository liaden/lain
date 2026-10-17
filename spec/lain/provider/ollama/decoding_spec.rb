# frozen_string_literal: true

# Ollama's failure mode is silence: HTTP 200, `done_reason: "stop"`, and a
# message whose every speaking field is blank -- which the wire calls an
# ordinary end of turn and nothing above the provider can tell from one. So the
# decoder that knows this model family reads it as a typed outcome: a record
# carrying the evidence, and a stop reason that fails the turn.
#
# Driven through the mixin rather than through {Lain::Provider::Ollama}, the way
# {Lain::Provider::Ollama::Encoding} is: the round trip, the retry ladder and the
# path-parity assertions belong to the class, and none of them is what these
# examples are about.
RSpec.describe Lain::Provider::Ollama::Decoding do
  # The journal is handed to each decode rather than read off the includer, so
  # an includer with no journal of its own can decode -- an Array is the whole
  # of the `#<<` the decoder sends.
  def decoder = Class.new { include Lain::Provider::Ollama::Decoding }.new

  def decode(body, journal = [], ceiling = nil)
    decoder.send(:build_response, body, ceiling, journal)
  end

  def body(done_reason: "stop", **message)
    { "model" => "qwen3:4b", "done" => true, "done_reason" => done_reason,
      "message" => { "role" => "assistant" }.merge(message.transform_keys(&:to_s)),
      "prompt_eval_count" => 11, "eval_count" => 0 }
  end

  def records(body)
    journal = []
    decode(body, journal)
    journal
  end

  describe "a reply that says nothing at all" do
    it "reads as malformed rather than as a finished turn" do
      expect(decode(body(content: ""))).to stop_with(Lain::StopReason::MALFORMED)
    end

    it "journals an empty_answer record naming the model that produced it" do
      expect(records(body(content: ""))).to eq(
        [Lain::Telemetry::MalformedResponse.new(kind: :empty_answer, model: "qwen3:4b")]
      )
    end

    # The stop reason is what fails the turn and the record is what a human
    # checks the reading against, so a truncated reply owes BOTH: the wire's own
    # `:max_tokens` survives, which is how a caller tells a spent ceiling from a
    # model that chose to stop, and the silence is still on the record.
    it "keeps the wire's :max_tokens for a truncated reply, and records the silence anyway" do
      truncated = body(content: "", done_reason: "length")

      expect(decode(truncated)).to stop_with(Lain::StopReason::MAX_TOKENS)
      expect(records(truncated).map(&:kind)).to eq([:empty_answer])
    end

    # `String#strip` and byte-equality both call U+00A0 content, and it is
    # exactly what a model spends its budget thinking and then emits. Blankness
    # is the one definition of "nothing at all" in this codebase.
    it "counts a single non-breaking space as nothing, not as a text block" do
      response = decode(body(content: " "))

      expect(response.content).to be_empty
      expect(response).to stop_with(Lain::StopReason::MALFORMED)
    end
  end

  # Three controls, because a reading that fires on an ordinary turn costs more
  # than the silence it was built to catch: the run lands in `:failed`.
  describe "a reply that says something" do
    it "leaves an honest :end_turn, and journals nothing, for a text answer" do
      answer = body(content: "Start with the Gemfile.")

      expect(decode(answer)).to stop_with(Lain::StopReason::END_TURN)
      expect(records(answer)).to be_empty
    end

    it "leaves a tool call alone even when it carries no text" do
      called = body(content: "", tool_calls: [{ "function" => { "name" => "bash", "arguments" => {} } }])

      expect(decode(called)).to stop_with(Lain::StopReason::TOOL_USE)
      expect(records(called)).to be_empty
    end

    # A model that reasons and then answers with nothing has still said nothing;
    # a model whose whole turn is its reasoning has spoken through the field
    # ollama gives it, and the thinking block reaches the Timeline.
    it "leaves a turn whose only speech is its thinking alone" do
      thought = body(content: "", thinking: "weighing the options")

      expect(decode(thought)).to stop_with(Lain::StopReason::END_TURN)
      expect(records(thought)).to be_empty
    end
  end

  describe "a tool call cut off by the token ceiling" do
    let(:cut) { "<tool_call>\n<function=list_files" }
    let(:truncated) { body(content: "Checking.\n#{cut}", done_reason: "length") }

    it "keeps max_tokens and drops the cut tail from the text" do
      response = decode(truncated)

      expect(response).to stop_with(Lain::StopReason::MAX_TOKENS)
      expect(response.text).to eq("Checking.")
    end

    it "journals one cut_tool_call record quoting the tail" do
      expect(records(truncated)).to eq(
        [Lain::Telemetry::MalformedResponse.new(kind: :cut_tool_call, model: "qwen3:4b", excerpt: cut)]
      )
    end

    it "leaves ordinary prose at the ceiling whole and unrecorded" do
      prose = body(content: "Start with the Gemfile and then", done_reason: "length")

      expect(decode(prose).text).to eq("Start with the Gemfile and then")
      expect(records(prose)).to be_empty
    end

    it "leaves a function= quoted mid-sentence at the ceiling as prose" do
      quoted = body(content: "see <function= syntax", done_reason: "length")

      expect(decode(quoted).text).to eq("see <function= syntax")
      expect(records(quoted)).to be_empty
    end

    it "records a cut that opens at the start of the text, with nothing kept" do
      bare = body(content: cut, done_reason: "length")
      response = decode(bare)

      expect(response.content).to be_empty
      expect(response).to stop_with(Lain::StopReason::MAX_TOKENS)
      expect(records(bare).map(&:kind)).to eq([:cut_tool_call])
    end

    it "records the cut envelope that follows a closed one" do
      closed = "<tool_call>\n<function=bash>\n</function>\n</tool_call>\nthen\n#{cut}"
      two = body(content: closed, done_reason: "length")

      expect(records(two).map(&:excerpt)).to eq([cut])
    end

    it "strips a cut that follows complete calls, and the calls still run" do
      calls = %w[read_file grep glob].map { |name| { "function" => { "name" => name, "arguments" => {} } } }
      after_calls = body(content: "Reading.\n<tool_call>\n<function=bash", tool_calls: calls, done_reason: "length")
      response = decode(after_calls)

      expect(response.tool_uses.map(&:name)).to eq(%w[read_file grep glob])
      expect(response).to stop_with(Lain::StopReason::TOOL_USE)
      expect(response.text).to eq("Reading.")
      expect(records(after_calls).map(&:kind)).to eq([:cut_tool_call])
    end
  end

  # A model that stops on its own just after opening a call has written markup
  # no parser will act on, and left in the text it is replayed as speech.
  describe "a bare tool_call opener at a normal stop" do
    let(:trailing) { body(content: "42.\n<tool_call>") }

    it "keeps the answer, drops the opener, and still settles as an answer" do
      response = decode(trailing)

      expect(response.text).to eq("42.")
      expect(response).to stop_with(Lain::StopReason::END_TURN)
    end

    it "journals one bare_tool_call record quoting the opener" do
      expect(records(trailing)).to eq(
        [Lain::Telemetry::MalformedResponse.new(kind: :bare_tool_call, model: "qwen3:4b", excerpt: "<tool_call>")]
      )
    end

    it "drops an opener the model began naming a function in" do
      named = body(content: "Checking.\n<tool_call>\n<function=list_files")

      expect(decode(named).text).to eq("Checking.")
      expect(records(named).map(&:kind)).to eq([:bare_tool_call])
    end

    it "judges silence on what is left, so markup alone is an empty answer" do
      alone = body(content: "<tool_call>")
      response = decode(alone)

      expect(response.content).to be_empty
      expect(response).to stop_with(Lain::StopReason::MALFORMED)
      expect(response.failure.message).to eq(Lain::Response::Failure::SILENT)
      expect(response.malformed).to eq(:empty_answer)
      expect(records(alone).map(&:kind)).to eq(%i[bare_tool_call empty_answer])
    end

    # The shape QA caught, and most of the leaks the recorded corpus holds.
    it "drops an opener written on the answer's own line" do
      same_line = body(content: "42.<tool_call>")

      expect(decode(same_line).text).to eq("42.")
      expect(records(same_line).map(&:excerpt)).to eq(["<tool_call>"])
    end

    it "drops every opener repeated at the end, under one record" do
      repeated = body(content: "x\n<tool_call>\n<tool_call>")

      expect(decode(repeated).text).to eq("x")
      expect(records(repeated).map(&:kind)).to eq([:bare_tool_call])
    end

    it "drops an envelope begun with arguments and never closed, and records it" do
      unclosed = body(content: "Ok.\n<tool_call>\n<function=bash>\n<parameter=command>\nls")

      expect(decode(unclosed).text).to eq("Ok.")
      expect(records(unclosed)).to eq(
        [Lain::Telemetry::MalformedResponse.new(kind: :bare_tool_call, model: "qwen3:4b",
                                                excerpt: "<tool_call>\n<function=bash>\n<parameter=command>\nls")]
      )
    end

    # Recorded verbatim in shape: the opener on the prose's own line, a hyphenated name.
    it "drops an unclosed envelope opened at the end of a line of prose" do
      mid_line = body(content: "Final assessment:<tool_call>\n<function=qa-answer>\n{\"verdict\": 1}\n</parameter>")

      expect(decode(mid_line).text).to eq("Final assessment:")
      expect(records(mid_line).map(&:kind)).to eq([:bare_tool_call])
    end

    it "drops an envelope that ends at a closed parameter" do
      closed = body(content: "Ok.\n<function=bash>\n<parameter=command>ls</parameter>")

      expect(decode(closed).text).to eq("Ok.")
    end

    # An answer ABOUT the envelope format ends in prose or a fence, never in
    # argument markup, and every word of it is the answer.
    {
      "an example the model talked past" =>
        "Example:\n<function=bash>\n<parameter=command>ls</parameter>\n\nThat is the format.",
      "a line-start mention of the opener" => "Write the opener as\n<function=name> then arguments, and close it.",
      "a fenced example" => "Example:\n```\n<function=bash>\n<parameter=command>ls\n```\nThat is the format."
    }.each do |shape, prose|
      it "keeps the whole of #{shape}" do
        expect(decode(body(content: prose)).text).to eq(prose)
        expect(records(body(content: prose))).to be_empty
      end
    end

    it "leaves a line-start tool_call tag the model talked past alone" do
      talked_past = body(content: "Calls look like:\n<tool_call>\nand the parser reads them.")

      expect(decode(talked_past).text).to eq("Calls look like:\n<tool_call>\nand the parser reads them.")
      expect(records(talked_past)).to be_empty
    end

    it "leaves a tool_call tag discussed mid-answer alone" do
      discussed = body(content: "Wrap it in a <tool_call> tag and the parser reads it.")

      expect(decode(discussed).text).to eq("Wrap it in a <tool_call> tag and the parser reads it.")
      expect(records(discussed)).to be_empty
    end
  end

  # Left in the text, the envelope is replayed to the model as something it
  # said and teaches it the very shape that failed.
  describe "a tool call written as prose" do
    let(:envelope) { "<tool_call>\n<function=bash>\n<parameter=command>\nls\n</parameter>\n</function>\n</tool_call>" }

    it "withholds the envelope and names the kind on the response" do
      response = decode(body(content: "Listing.\n#{envelope}"))

      expect(response).to stop_with(Lain::StopReason::MALFORMED)
      expect(response.malformed).to eq(:prose_tool_call)
      expect(response.text).to eq("Listing.")
    end

    it "withholds every opener the envelope was written under" do
      response = decode(body(content: "Listing.\n<tool_call>\n#{envelope}"))

      expect(response.text).to eq("Listing.")
    end

    it "says the call was withheld when the envelope was all the model wrote" do
      response = decode(body(content: envelope))

      expect(response.text).to eq("(a tool call written as text was withheld)")
      expect(response.failure.message).to eq(Lain::Response::Failure::PROSE_CALL)
    end

    it "keeps a text block beside the thinking, so the turn is never thinking alone" do
      response = decode(body(content: envelope, thinking: "I should list the files"))

      expect(response.content.map { |block| block["type"] }).to eq(%w[thinking text])
    end

    it "quotes the envelope it withheld" do
      expect(records(body(content: envelope)).map(&:excerpt)).to all(include("<function=bash>"))
    end
  end

  # The override is keyed on the reason the decode ARRIVES AT, never on the
  # wire string that suggested it. `StopReason.normalize` admits the whole of
  # `KNOWN`, so an ollama-compatible server answering `"end_turn"` or
  # `"stop_sequence"` reaches a reason the loop machine settles as `:done` --
  # and a run reporting success over an `empty_answer` record is the exact
  # failure this decode exists to abolish.
  describe "a done_reason the wire is free to spell any way it likes" do
    %w[end_turn stop_sequence].each do |spelling|
      it "refuses to settle silence as an answer under done_reason #{spelling.inspect}" do
        silent = body(content: "", done_reason: spelling)

        expect(decode(silent)).to stop_with(Lain::StopReason::MALFORMED)
        expect(records(silent).map(&:kind)).to eq([:empty_answer])
      end

      it "leaves done_reason #{spelling.inspect} alone when the turn actually said something" do
        spoken = body(content: "Start with the Gemfile.", done_reason: spelling)

        expect(decode(spoken)).to stop_with(spelling.to_sym)
        expect(records(spoken)).to be_empty
      end
    end
  end

  # One file, two readings of the same text: the anchor that decides a prose
  # envelope ENDED the turn, and the predicate that decides the turn said
  # nothing. `\s` left them disagreeing about the zero-width set, so a model
  # that closed its envelope and emitted a U+200B was read as having talked
  # past it -- the narrowing firing on exactly the turn it was not for.
  it "still reads an envelope the model closed and then padded with a zero-width character" do
    padded = body(content: "<function=bash>\n<parameter=command>\nls\n</parameter>\n</function>​")

    expect(decode(padded)).to stop_with(Lain::StopReason::MALFORMED)
    expect(records(padded).map(&:kind)).to eq([:prose_tool_call])
  end

  # The other half of the same rule: a reason that already says something a
  # caller can act on keeps saying it. "" is a connection that closed and
  # already fails the turn as `:unknown`, under the diagnostic that names what
  # actually happened; replacing it would trade a cause for a consequence.
  it "leaves an unrecognized done_reason its own :unknown, and still records the silence" do
    closed = body(content: "", done_reason: "")

    expect(decode(closed)).to stop_with(Lain::StopReason::UNKNOWN)
    expect(records(closed).map(&:kind)).to eq([:empty_answer])
  end

  # ollama says `length` for two different cuts: the request's own num_predict
  # spent, or the context window filled (the shift is refused). Only the count
  # tells them apart, and only the provider knows the ceiling it sent.
  describe "a length stop" do
    def cut(eval_count) = body(content: "x", done_reason: "length").merge("eval_count" => eval_count)

    it "is marked a window cut when it fell short of the ceiling" do
      expect(decode(cut(300), [], 1024).window_cut).to be(true)
    end

    it "is not marked when the ceiling itself was spent" do
      expect(decode(cut(1024), [], 1024).window_cut).to be(false)
    end

    it "is not marked when no count was reported" do
      expect(decode(cut(0), [], 1024).window_cut).to be(false)
    end

    it "is not marked when no ceiling is known" do
      expect(decode(cut(300)).window_cut).to be(false)
    end

    it "is not marked on a stop that was not a length" do
      expect(decode(body(content: "x").merge("eval_count" => 5), [], 1024).window_cut).to be(false)
    end
  end
end
