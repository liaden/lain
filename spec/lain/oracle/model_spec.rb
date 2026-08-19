# frozen_string_literal: true

# T2: the model-backed oracle tier. It renders the question, completes it against
# a provider, decodes the reply, and validates it into the typed answer -- raising
# on an answer the schema rejects rather than defaulting. Driven here against
# Provider::Mock so no token is spent.
RSpec.describe Lain::Oracle::Model do
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

  def response_with(text)
    Lain::Response.new(content: [{ "type" => "text", "text" => text }], stop_reason: :end_turn)
  end

  def oracle(response)
    provider = Lain::Provider::Mock.new(responses: [response])
    [Lain::Oracle::Model.new(definition:, provider:, model: "test-model"), provider]
  end

  # ---- Scenario: a model oracle returns a validated typed answer ------------

  it "yields the coerced typed answer when the provider returns a valid reply" do
    model, = oracle(response_with(%({"label":"yes","score":"0.8"})))

    answer = Sync { model.ask(subject: "aspirin").await }

    expect(answer.label).to eq("yes")
    expect(answer.score).to eq(0.8)
  end

  it "sends the rendered question to the provider" do
    model, provider = oracle(response_with(%({"label":"no"})))

    Sync { model.ask(subject: "aspirin").await }

    expect(provider.last_request.messages.first["content"]).to eq("Is aspirin relevant?")
  end

  # ---- Scenario: an invalid answer raises rather than defaulting ------------

  it "raises loudly when the reply fails the schema" do
    model, = oracle(response_with(%({"label":"maybe"})))

    expect { Sync { model.ask(subject: "x").await } }.to raise_error(Lain::Oracle::InvalidAnswer)
  end

  it "raises when the reply is not decodable JSON" do
    model, = oracle(response_with("not json at all"))

    expect { Sync { model.ask(subject: "x").await } }.to raise_error(Lain::Oracle::UndecodableAnswer)
  end

  # ---- Scenario: an oracle asks a structured-output-capable provider for JSON -
  #
  # Driven through the REAL construction site rather than an injected
  # collaborator: {CLI::Backend::Summarizer} is what builds the summarizer's
  # Oracle::Model, and ollama is its default provider. The defect these cover
  # was invisible anywhere shallower -- the tier sent no #extra at all, so
  # nothing ever asked for grammar-constrained decoding and qwen3-coder answered
  # the summarizer in markdown, raising UndecodableAnswer and leaving every span
  # uncollapsed.
  describe "structured output" do
    let(:source) { "a long tool result" }
    let(:max_tokens) { 256 }

    # `model` is a parameter because the provider under test decides what a
    # plausible model id looks like, and an ollama id sent to Provider::Anthropic
    # reads as a mistake even where it is inert.
    def summarizer_oracle(provider, model:)
      # {CLI::Backend#summarizer_provider} takes the caller's willingness to
      # QUEUE for provider capacity (open decision 4), and a bare Struct member
      # reader takes no arguments -- so the double has to speak the real message
      # or it has stopped standing in for the thing it doubles.
      backend = Struct.new(:summarizer_provider, :summarizer_model, :summarizer_max_tokens, :journal) do
        def summarizer_provider(queue: true) = self[:summarizer_provider] # rubocop:disable Lint/UnusedMethodArgument
      end.new(provider, model, max_tokens, Lain::Channel::Null::INSTANCE)
      Lain::CLI::Backend::Summarizer.new(backend:).oracle
    end

    def summary_reply(text)
      Lain::Response.new(content: [{ "type" => "text", "text" => text }], stop_reason: :end_turn)
    end

    it "sends the answer schema as ollama's format field when the provider declares structured_output" do
      transport = OllamaWire.queue_transport([summary_reply(%({"summary":"three files, one stale"}))])
      oracle = summarizer_oracle(Lain::Provider::Ollama.new(transport:), model: "qwen3-coder:30b")

      Sync { oracle.ask(source:).await }

      expect(transport.calls.last[:format]).to eq(Lain::Oracle::Summarize::SCHEMA.to_json_schema)
    end

    # The assertion is on the REQUEST, not the encoded body, and deliberately:
    # Mock#encode returns Request#cache_payload, which excludes #extra by design,
    # so a body assertion here could not fail either way. `extra` empty is the
    # claim that can -- deleting the capability gate turns it red.
    it "asks a provider without the capability plainly, and still parses its JSON reply" do
      provider = Lain::Provider::Mock.new(responses: [summary_reply(%({"summary":"three files"}))],
                                          capabilities: Lain::Provider::CAPABILITIES - [:structured_output])

      answer = Sync { summarizer_oracle(provider, model: "mock-1").ask(source:).await }

      expect(provider.last_request.extra).to be_empty
      expect(answer.summary).to eq("three files")
    end

    # This card's escalation guard, made at the level the claim is made: BYTES.
    # Provider::Anthropic does not declare structured_output, so the marker must
    # never reach its encoder -- which reads the same neutral key to force
    # tool_choice, and a changed prefix is a prompt-cache break (CLAUDE.md:
    # purity and cache-hit are the same constraint).
    #
    # Asserting the ABSENCE of a :structured_output key would prove nothing here:
    # AnthropicEncoding#encode strips that key unconditionally, so it is
    # unreachable in this payload by construction. Serializing the real wire body
    # and comparing it against the same question asked with no #extra at all is
    # what actually catches a leak.
    it "sends the Anthropic path byte-identical wire bytes to a request carrying no extra" do
      transport = AnthropicSSE.queue_transport([summary_reply(%({"summary":"three files"}))])
      provider = Lain::Provider::Anthropic.new(transport:, api_key: "test")

      Sync { summarizer_oracle(provider, model: "claude-opus-4-8").ask(source:).await }
      sent = JSON.generate(transport.calls.last)
      provider.complete(plain_request("claude-opus-4-8"))

      expect(sent).to eq(JSON.generate(transport.calls.last))
    end

    # The same question the summarizer oracle asks, built by hand with no #extra
    # -- the baseline the bytes above must match.
    def plain_request(model)
      question = Lain::Oracle::Summarize.definition.render(source:)
      Lain::Request.new(model:, max_tokens:, messages: [{ "role" => "user", "content" => question }])
    end
  end
end
