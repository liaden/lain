# frozen_string_literal: true

require "stringio"

# T3: an oracle call is journaled as a {Telemetry::OracleAnswer} record, and
# {Oracle::Recorded.from_journal} substitutes the recorded answer on replay --
# keyed by `(oracle_digest, question)`, with a MISS raising rather than silently
# re-asking the model. The same "recorded is a replay of a real interpretation"
# discipline as {Effect::Handler::Recorded} and {Grader::Refuter::Recorded}, one
# tier over: keyed on the oracle's own content digest, so a changed schema (a
# different digest) misses loudly instead of matching a stale answer.
RSpec.describe Lain::Oracle::Recorded do
  let(:schema) do
    Class.new(Lain::Tool::Input) do
      field :label, :string, required: true, description: "the verdict label"
      field :score, :float, description: "confidence in 0..1"
      validates :label, inclusion: { in: %w[yes no] }
    end
  end

  let(:definition) do
    Lain::Oracle::Definition.new(template: %(Is <%= render("subject") %> relevant?), schema:, tier: :model)
  end

  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  def response_with(text)
    Lain::Response.new(content: [{ "type" => "text", "text" => text }], stop_reason: :end_turn)
  end

  # Record ONE oracle call through a live model tier over Provider::Mock, wrapped
  # in the journaling decorator. Returns the provider so a spec can assert the
  # replay path adds no further #complete call. The scripted Response carries a
  # real Usage so the journaled cost is a genuine, non-empty count.
  def record(inputs: { subject: "aspirin" }, text: %({"label":"yes","score":"0.8"}), model: "test-model",
             usage: Lain::Usage.new(input_tokens: 12, output_tokens: 7))
    response = Lain::Response.new(content: [{ "type" => "text", "text" => text }], stop_reason: :end_turn, usage:)
    provider = Lain::Provider::Mock.new(responses: [response])
    tier = Lain::Oracle::Model.new(definition:, provider:, model:)
    journaling = described_class::Journaling.new(inner: tier, definition:, journal:)
    Sync { journaling.ask(**inputs).await }
    provider
  end

  # The {Journal.records} duck is an Enumerable of entries (lines or Hashes),
  # the `File.foreach(path)` shape every reader takes -- so split the StringIO's
  # bytes into lines the way Handler::Recorded/Refuter::Recorded callers do.
  def replay(definition: self.definition)
    described_class.from_journal(journal_io.string.each_line, definition:)
  end

  def oracle_answers
    Lain::Journal.records(journal_io.string.each_line, type: "oracle_answer")
  end

  # ---- Scenario: a recorded oracle answer is substituted on replay ----------

  describe "substituting a recorded answer" do
    it "returns the recorded answer with no further provider call" do
      provider = record
      expect(provider.call_count).to eq(1)

      answer = Sync { replay.ask(subject: "aspirin").await }

      expect(answer.label).to eq("yes")
      expect(answer.score).to eq(0.8)
      expect(provider.call_count).to eq(1)
    end

    it "re-validates the recorded attributes through the definition's schema" do
      record

      answer = Sync { replay.ask(subject: "aspirin").await }

      expect(answer).to be_a(schema)
      expect(answer).to be_valid
    end

    it "consumes same-question recordings FIFO, in the order they were journaled" do
      provider = Lain::Provider::Mock.new(responses: [response_with(%({"label":"yes"})),
                                                      response_with(%({"label":"no"}))])
      tier = Lain::Oracle::Model.new(definition:, provider:, model: "test-model")
      journaling = described_class::Journaling.new(inner: tier, definition:, journal:)
      Sync { journaling.ask(subject: "aspirin").await }
      Sync { journaling.ask(subject: "aspirin").await }

      recorded = replay
      expect(Sync { recorded.ask(subject: "aspirin").await }.label).to eq("yes")
      expect(Sync { recorded.ask(subject: "aspirin").await }.label).to eq("no")
    end
  end

  # ---- Scenario: a deleted recording fails loudly ---------------------------

  describe "a missing recording" do
    it "raises rather than re-asking the model when the recording is absent" do
      # No record() call: the journal holds no oracle_answer at all.
      expect { Sync { replay.ask(subject: "aspirin").await } }
        .to raise_error(described_class::Unrecorded)
    end

    it "raises when the recording for THIS question was removed" do
      record(inputs: { subject: "aspirin" })

      expect { Sync { replay.ask(subject: "warfarin").await } }
        .to raise_error(described_class::Unrecorded)
    end

    it "does not silently re-ask once a queued recording is exhausted" do
      record
      recorded = replay
      Sync { recorded.ask(subject: "aspirin").await }

      expect { Sync { recorded.ask(subject: "aspirin").await } }
        .to raise_error(described_class::Unrecorded)
    end
  end

  # ---- Escalation: a changed oracle schema orphans recordings loudly --------

  describe "staleness of a changed oracle schema" do
    let(:changed_schema) do
      Class.new(Lain::Tool::Input) do
        field :label, :string, required: true, description: "the verdict label"
        field :confidence, :float, description: "renamed field -- a different oracle"
      end
    end

    let(:changed_definition) do
      Lain::Oracle::Definition.new(template: %(Is <%= render("subject") %> relevant?),
                                   schema: changed_schema, tier: :model)
    end

    it "gives the changed definition a different digest" do
      expect(changed_definition.digest).not_to eq(definition.digest)
    end

    it "misses loudly rather than matching a stale answer" do
      record

      expect { Sync { replay(definition: changed_definition).ask(subject: "aspirin").await } }
        .to raise_error(described_class::Unrecorded)
    end
  end

  # ---- The OracleAnswer Journal record --------------------------------------

  describe "the journaled OracleAnswer record" do
    it "writes exactly one valid NDJSON oracle_answer line" do
      record

      expect(journal_io).to be_valid_ndjson
      expect(journal_io).to include_journal_record("oracle_answer", oracle_digest: definition.digest)
    end

    it "carries the rendered question, the answer attributes, and the model" do
      record

      record_hash = oracle_answers.first
      expect(record_hash["question"]).to eq("Is aspirin relevant?")
      expect(record_hash["answer"]).to eq("label" => "yes", "score" => 0.8)
      expect(record_hash["model"]).to eq("test-model")
      expect(record_hash["wall_clock"]).to be_a(Numeric)
    end

    it "records the wrapped model tier's REAL token usage, threaded from its Response" do
      record(usage: Lain::Usage.new(input_tokens: 12, output_tokens: 7))

      usage = oracle_answers.first.fetch("usage")
      expect(usage).to include("input_tokens" => 12, "output_tokens" => 7)
    end

    it "records empty usage and a nil model for a model-free heuristic tier" do
      tier = Lain::Oracle::Heuristic.new(definition:, predicate: ->(_) { { "label" => "no" } })
      journaling = described_class::Journaling.new(inner: tier, definition:, journal:)
      Sync { journaling.ask(subject: "aspirin").await }

      record_hash = oracle_answers.first
      expect(record_hash["usage"]).to eq({})
      expect(record_hash["model"]).to be_nil
    end

    it "is a Ractor-shareable value object" do
      answer = Lain::Telemetry::OracleAnswer.new(
        oracle_digest: definition.digest, question: "Is aspirin relevant?",
        answer: { "label" => "yes" }, model: "test-model", usage: {}, wall_clock: 0.1
      )
      expect(answer).to be_ractor_shareable
    end
  end

  # ---- Scenario: replaying a session with oracles is byte-identical ----------

  describe "DryReplay byte-identity with oracle substitution active" do
    # The recorded session's renders never consumed oracle output (oracles sit
    # ABOVE the cache line -- Definition#render is pure and separate from
    # Context#render), so substituting recorded answers cannot perturb the
    # re-rendered request bytes. This proves the two are independent: the oracle
    # answers come from the journal (no provider call) while DryReplay reproduces
    # the baseline byte-for-byte.
    let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
    let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }

    it "reproduces byte-identical Requests while the oracle answers from the journal" do
      record
      agent, provider = record_run([tool_response(["tu_1", "echo", { "text" => "hi" }]), text_response("done")],
                                   toolset:, context:)

      substituted = Sync { replay.ask(subject: "aspirin").await }
      expect(substituted.label).to eq("yes")

      diff = Lain::Bench::DryReplay.new(timeline: agent.timeline, baseline: provider.requests, toolset:).diff(context)
      expect(diff).to be_identical
    end
  end
end
