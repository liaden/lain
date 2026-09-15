# frozen_string_literal: true

require "json"
require "stringio"

RSpec.describe Lain::Agent::Accounting do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  def records
    journal_io.string.each_line.map { |line| JSON.parse(line) }
  end

  def response(input: 10, output: 5, model: "claude-opus-4-8", stop_reason: :end_turn,
               usage: Lain::Usage.new(input_tokens: input, output_tokens: output))
    Lain::Response.new(
      content: [{ "type" => "text", "text" => "hi" }],
      stop_reason:, model:, usage:
    )
  end

  # A real Ollama `/api/chat` body that finished a turn without reporting what
  # the prompt cost -- the field is simply absent, which the streaming assembler
  # is separately pinned to reproduce. Routed through the real decoder rather
  # than hand-built, because the Usage shape this yields (a zero input beside a
  # large output) is the one a hand-written fixture does not think to try.
  def ollama_body_missing_prompt_eval_count
    { "model" => "qwen3:4b", "created_at" => "2026-08-17T23:28:20.042698269Z",
      "message" => { "role" => "assistant", "content" => "done" },
      "done" => true, "done_reason" => "stop",
      "total_duration" => 1_292_212_105, "load_duration" => 224_965_477,
      "eval_count" => 250, "eval_duration" => 929_828_000 }
  end

  def ollama_usage(body)
    Object.new.extend(Lain::Provider::Ollama::Decoding).send(:build_usage, body)
  end

  it "starts at Usage.zero" do
    expect(described_class.new.usage).to eq(Lain::Usage.zero)
  end

  describe "#observe" do
    it "accumulates the Usage monoid and returns the cumulative total" do
      accounting = described_class.new

      first = accounting.observe(response(input: 10, output: 5), digest: "blake3:one")
      expect(first).to eq(Lain::Usage.new(input_tokens: 10, output_tokens: 5))

      second = accounting.observe(response(input: 3, output: 2), digest: "blake3:two")
      expect(second).to eq(Lain::Usage.new(input_tokens: 13, output_tokens: 7))
      expect(accounting.usage).to eq(second)
    end

    it "journals one turn_usage record per observation, keyed by the committed turn's digest" do
      accounting = described_class.new(journal:)
      accounting.observe(response, digest: "blake3:one")
      accounting.observe(response(input: 3, output: 2), digest: "blake3:two")

      expect(records.map { |record| record["type"] }).to eq(%w[turn_usage turn_usage])
      expect(records.map { |record| record["digest"] }).to eq(%w[blake3:one blake3:two])
      expect(journal_io).to include_journal_record(
        "turn_usage", digest: "blake3:one", model: "claude-opus-4-8", stop_reason: "end_turn",
                      usage: { "input_tokens" => 10, "output_tokens" => 5,
                               "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => 0 }
      )
    end

    it "records each turn's OWN usage, not the running total" do
      accounting = described_class.new(journal:)
      accounting.observe(response(input: 10, output: 5), digest: "blake3:one")
      accounting.observe(response(input: 3, output: 2), digest: "blake3:two")

      expect(records.last["usage"]).to include("input_tokens" => 3, "output_tokens" => 2)
    end

    it "needs no journal: the default Null channel absorbs the record" do
      accounting = described_class.new
      expect { accounting.observe(response, digest: "blake3:one") }.not_to raise_error
      expect(accounting.usage.total_tokens).to eq(15)
    end

    it "tolerates a response with no model, as a bare mock produces" do
      accounting = described_class.new(journal:)
      accounting.observe(response(model: nil), digest: "blake3:one")

      expect(journal_io).to include_journal_record("turn_usage", model: nil)
    end
  end

  # A reading is about a chain, so it is asked of one. These chains are real:
  # whether a reading still stands is a question about ancestry, which only a
  # Store can answer.
  describe "#last_turn_usage" do
    let(:line) do
      %w[user assistant user assistant].each_with_index.inject(Lain::Timeline.empty) do |grown, (role, index)|
        grown.commit(role:, content: [{ "type" => "text", "text" => "turn #{index}" }])
      end
    end

    def at(index) = line.checkout(line.to_a[index].digest)

    def digest(index) = line.to_a[index].digest

    it "is nil before any turn -- unknown, not zero" do
      expect(described_class.new.last_turn_usage(on: line)).to be_nil
    end

    it "reports the most recent response's input tokens, not the sum" do
      accounting = described_class.new
      accounting.observe(response(input: 100, output: 5), digest: digest(1))
      accounting.observe(response(input: 250, output: 5), digest: digest(3))

      expect(accounting.last_turn_usage(on: line)).to eq(250)
      expect(accounting.usage.total_input_tokens).to eq(350)
    end

    context "when the chain has moved since the reading was taken" do
      it "still reads it on a chain grown past the turn it was taken at" do
        accounting = described_class.new
        accounting.observe(response(input: 250, output: 5), digest: digest(1))

        expect(accounting.last_turn_usage(on: line)).to eq(250)
      end

      it "reads it on the very turn it was taken at" do
        accounting = described_class.new
        accounting.observe(response(input: 250, output: 5), digest: digest(3))

        expect(accounting.last_turn_usage(on: at(3))).to eq(250)
      end

      it "reads as absent, and never as zero, once a rewind drops the turn it was taken at" do
        accounting = described_class.new
        accounting.observe(response(input: 250, output: 5), digest: digest(3))

        expect(accounting.last_turn_usage(on: at(2))).to be_nil
      end

      it "reads as absent on a branch that never held that turn" do
        accounting = described_class.new
        accounting.observe(response(input: 250, output: 5), digest: digest(3))
        branch = at(2).commit(role: "assistant", content: [{ "type" => "text", "text" => "another answer" }])

        expect(accounting.last_turn_usage(on: branch)).to be_nil
      end

      it "comes back when the chain returns to the turn it was taken at" do
        accounting = described_class.new
        accounting.observe(response(input: 250, output: 5), digest: digest(3))
        accounting.last_turn_usage(on: at(2))

        expect(accounting.last_turn_usage(on: line)).to eq(250)
      end
    end

    context "when a response reports no usage at all" do
      it "leaves the last real reading standing rather than reading as an empty context" do
        accounting = described_class.new
        accounting.observe(response(input: 100, output: 5), digest: digest(1))
        accounting.observe(response(input: 0, output: 0), digest: digest(3))

        expect(accounting.last_turn_usage(on: line)).to eq(100)
      end

      it "still folds the zero turn into the cumulative total" do
        accounting = described_class.new
        accounting.observe(response(input: 100, output: 5), digest: digest(1))
        accounting.observe(response(input: 0, output: 0), digest: digest(3))

        expect(accounting.usage).to eq(Lain::Usage.new(input_tokens: 100, output_tokens: 5))
      end

      it "still journals a turn_usage record for the turn, which was paid for either way" do
        accounting = described_class.new(journal:)
        accounting.observe(response(input: 100, output: 5), digest: "blake3:one")
        accounting.observe(response(input: 0, output: 0), digest: "blake3:zero")

        expect(records.map { |record| record["type"] }).to eq(%w[turn_usage turn_usage])
        expect(records.last["digest"]).to eq("blake3:zero")
        expect(records.last["usage"]).to include("input_tokens" => 0, "output_tokens" => 0)
      end

      it "is still absent when the very first response reports no usage" do
        accounting = described_class.new
        accounting.observe(response(input: 0, output: 0), digest: digest(1))

        expect(accounting.last_turn_usage(on: line)).to be_nil
      end

      it "is the shape Ollama yields when the body omits prompt_eval_count" do
        usage = ollama_usage(ollama_body_missing_prompt_eval_count)

        expect(usage.total_input_tokens).to eq(0)
        expect(usage.output_tokens).to eq(250)
      end

      it "leaves a real reading standing when Ollama reports output but no prompt cost" do
        accounting = described_class.new
        accounting.observe(response(input: 900_000, output: 5), digest: digest(1))
        accounting.observe(
          response(usage: ollama_usage(ollama_body_missing_prompt_eval_count)),
          digest: digest(3)
        )

        expect(accounting.last_turn_usage(on: line)).to eq(900_000)
      end

      it "leaves the reading standing on a negative input sum, which neither type forbids" do
        accounting = described_class.new
        accounting.observe(response(input: 900_000, output: 5), digest: digest(1))
        accounting.observe(response(input: -10, output: 5), digest: digest(3))

        expect(accounting.last_turn_usage(on: line)).to eq(900_000)
      end

      it "takes the reading when only the output tokens are zero" do
        accounting = described_class.new
        accounting.observe(response(input: 100, output: 5), digest: digest(1))
        accounting.observe(response(input: 7, output: 0), digest: digest(3))

        expect(accounting.last_turn_usage(on: line)).to eq(7)
      end
    end
  end

  # A provider that refuses a prompt for not fitting its context has measured
  # it exactly, with its own tokenizer, against the context it loaded -- the
  # most believable reading a run can get, and the only one a refused turn
  # yields. Without it compaction's approaching-window signal keeps reading
  # the last answered turn and never fires, so every later prompt is refused
  # the same way.
  #
  # The refused prompt itself may be withdrawn, so the count is taken as
  # standing on the turn below it, which the Agent names.
  describe "#observe_refusal" do
    let(:line) do
      %w[user assistant user].each_with_index.inject(Lain::Timeline.empty) do |grown, (role, index)|
        grown.commit(role:, content: [{ "type" => "text", "text" => "turn #{index}" }])
      end
    end

    def at(index) = line.checkout(line.to_a[index].digest)

    def digest(index) = line.to_a[index].digest

    it "takes the provider's exact prompt count as the current reading" do
      accounting = described_class.new
      accounting.observe(response(input: 7_000, output: 5), digest: digest(1))

      accounting.observe_refusal(prompt_tokens: 12_011, head: digest(1))

      expect(accounting.last_turn_usage(on: line)).to eq(12_011)
    end

    it "is still believed once the refused prompt is withdrawn off the chain" do
      accounting = described_class.new
      accounting.observe_refusal(prompt_tokens: 12_011, head: digest(1))

      expect(accounting.last_turn_usage(on: at(1))).to eq(12_011)
    end

    it "reads as absent once a rewind drops the turn it stood on" do
      accounting = described_class.new
      accounting.observe_refusal(prompt_tokens: 12_011, head: digest(1))

      expect(accounting.last_turn_usage(on: at(0))).to be_nil
    end

    it "stands on any chain when the refused prompt was the first turn of all" do
      accounting = described_class.new

      accounting.observe_refusal(prompt_tokens: 12_011, head: nil)

      expect(accounting.last_turn_usage(on: Lain::Timeline.empty)).to eq(12_011)
      expect(accounting.last_turn_usage(on: line)).to eq(12_011)
    end

    it "spends nothing and records nothing, since nothing was generated or billed" do
      accounting = described_class.new(journal:)
      accounting.observe(response(input: 7_000, output: 5), digest: digest(1))

      accounting.observe_refusal(prompt_tokens: 12_011, head: digest(1))

      expect(accounting.usage).to eq(Lain::Usage.new(input_tokens: 7_000, output_tokens: 5))
      expect(records.size).to eq(1)
    end

    it "leaves the reading standing on a count that says nothing" do
      accounting = described_class.new
      accounting.observe(response(input: 7_000, output: 5), digest: digest(1))

      accounting.observe_refusal(prompt_tokens: 0, head: digest(1))

      expect(accounting.last_turn_usage(on: line)).to eq(7_000)
    end
  end
end
