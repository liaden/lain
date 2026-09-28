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
  # `@journal` is the one collaborator the mixin reaches for and cannot declare,
  # so an includer has to hand it one -- an Array is the whole of the `#<<`
  # the decoder sends.
  def decoder(journal = [])
    Class.new do
      include Lain::Provider::Ollama::Decoding

      def initialize(journal) = @journal = journal
    end.new(journal)
  end

  def decode(body, journal = [])
    decoder(journal).send(:build_response, body)
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
end
