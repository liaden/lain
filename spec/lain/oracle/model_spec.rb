# frozen_string_literal: true

# The model-backed oracle tier. It renders the question, completes it against
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

  # ---- Scenario: a tier carries the options its caller resolved -------------
  #
  # WHICH options a tier may carry is the caller's rule (see
  # {Lain::CLI::Backend#tier_options}); this object only has to put them on the
  # wire beside the schema, and never let them displace it.
  describe "caller-resolved options" do
    def tier_over(provider, extra:)
      Lain::Oracle::Model.new(definition:, provider:, model: "qwen3:4b", extra:)
    end

    def ollama_provider
      Lain::Provider::Mock.new(responses: [response_with(%({"label":"yes"}))],
                               capabilities: Lain::Provider::Ollama::CAPABILITIES)
    end

    it "sends them on the request, beside the answer schema" do
      provider = ollama_provider
      Sync { tier_over(provider, extra: { "num_batch" => 2048 }).ask(subject: "x").await }

      expect(provider.last_request.extra)
        .to eq("num_batch" => 2048, "think" => false,
               "structured_output" => { "schema" => schema.to_json_schema })
    end

    it "lets the schema win a collision, so no option can unset the answer's format" do
      provider = ollama_provider
      Sync { tier_over(provider, extra: { "structured_output" => { "schema" => {} } }).ask(subject: "x").await }

      expect(provider.last_request.extra["structured_output"]).to eq("schema" => schema.to_json_schema)
    end
  end

  # ---- Scenario: an oracle over a thinking model does not spend its ceiling --
  #                                                                 on thinking
  #
  # Measured, not theoretical: qwen3:4b spends 3.9k-8k characters reasoning
  # before it answers, so a 1024-token ceiling is gone before the first field of
  # the JSON object. The live secret-read example failed on exactly this.
  describe "thinking" do
    def tier_over(provider)
      Lain::Oracle::Model.new(definition:, provider:, model: "qwen3:4b")
    end

    def provider_with(capabilities)
      Lain::Provider::Mock.new(responses: [response_with(%({"label":"yes"}))], capabilities:)
    end

    it "turns thinking off where the wire has the field, so the ceiling buys an answer" do
      provider = provider_with(Lain::Provider::Ollama::CAPABILITIES)
      Sync { tier_over(provider).ask(subject: "x").await }

      expect(provider.last_request.extra["think"]).to be(false)
    end

    # The anthropic arm negotiates reasoning its own way and its encoder
    # forwards an `extra` key it does not know, so a `think` reaching it would
    # be both a bogus wire field and a moved prompt-cache prefix. The
    # byte-identical example further down is what proves the second half.
    it "sends no thinking field to an arm whose wire has none" do
      provider = provider_with(Lain::Provider::Anthropic::CAPABILITIES)
      Sync { tier_over(provider).ask(subject: "x").await }

      expect(provider.last_request.extra).not_to have_key("think")
    end
  end

  # ---- Scenario: an empty answer is retried once with room, then reported ----
  #
  # The narrow case only: the model said NOTHING AT ALL, so there is nothing to
  # decode and no evidence it would say the same twice. A reply that hit its cap
  # is a different finding and is not retried here.
  describe "a reply that says nothing" do
    def tier_over(provider, max_tokens: 512)
      Lain::Oracle::Model.new(definition:, provider:, model: "qwen3:4b", max_tokens:)
    end

    def provider_returning(*responses)
      Lain::Provider::Mock.new(responses:, capabilities: Lain::Provider::Ollama::CAPABILITIES)
    end

    def blank = response_with("")

    # The shape the ceiling produces on a thinking model: the whole budget went
    # into `message.thinking`, and the answer never started.
    def thinking_only
      Lain::Response.new(content: [{ "type" => "thinking", "thinking" => "let me see" }], stop_reason: :end_turn)
    end

    # At the SAME ceiling, because more room is not what a silence was about:
    # asked again with twice the budget the same model went quiet twice. What
    # the second ask buys is the nondeterminism.
    it "asks again under the same ceiling, and answers from the second reply" do
      provider = provider_returning(blank, response_with(%({"label":"yes"})))

      answer = Sync { tier_over(provider).ask(subject: "x").await }

      expect(provider.requests.map(&:max_tokens)).to eq([512, 512])
      expect(answer.label).to eq("yes")
    end

    it "reads a reply that is all reasoning and no answer as saying nothing" do
      provider = provider_returning(thinking_only, response_with(%({"label":"no"})))

      answer = Sync { tier_over(provider).ask(subject: "x").await }

      expect([provider.call_count, answer.label]).to eq([2, "no"])
    end

    it "asks exactly once when the first reply carries an answer" do
      provider = provider_returning(response_with(%({"label":"yes"})))

      Sync { tier_over(provider).ask(subject: "x").await }

      expect(provider.call_count).to eq(1)
    end

    it "names emptiness as the cause when the retry says nothing either" do
      provider = provider_returning(blank, blank)

      expect { Sync { tier_over(provider).ask(subject: "x").await } }
        .to raise_error(Lain::Oracle::UndecodableAnswer, /empty/i)
    end
  end

  # ---- Scenario: what an ask reports having spent ---------------------------
  #
  # {Lain::Oracle::Recorded::Journaling} reads this off the tier the moment the
  # ask returns and puts it on the record the bench's accounting reads, so an
  # ask reporting anything but its own round trips corrupts that record.
  describe "the spend it reports" do
    def costing(usage, text)
      Lain::Response.new(content: [{ "type" => "text", "text" => text }],
                         stop_reason: :end_turn, usage:)
    end

    def ollama_mock(responses)
      Lain::Provider::Mock.new(responses:,
                               capabilities: Lain::Provider::Ollama::CAPABILITIES)
    end

    # Parks mid-round-trip so a second ask starts before the first has a
    # response to account for. `sleep(0)` yields to the reactor rather than
    # waiting on a clock, which is what makes the interleaving deterministic.
    def parking_provider(responses)
      Class.new(Lain::Provider::Mock) do
        def complete(request, **)
          Async::Task.current.sleep(0)
          super
        end
      end.new(responses:, capabilities: Lain::Provider::Ollama::CAPABILITIES)
    end

    it "adds up BOTH round trips, so a retried answer is not a free one" do
      spent = Lain::Usage.new(input_tokens: 10, output_tokens: 4)
      provider = ollama_mock([costing(spent, ""), costing(spent, %({"label":"yes"}))])
      model = described_class.new(definition:, provider:, model: "qwen3:4b")

      Sync { model.ask(subject: "x").await }

      expect(model.usage).to include(input_tokens: 20, output_tokens: 8)
    end

    # One {Lain::Oracle::Eager} holds ONE tier and fires a task per tool-result
    # digest, so a turn with parallel tool calls overlaps two asks by
    # construction. A spend accumulated on the INSTANCE across the round trip's
    # suspension point puts the first ask's tokens on the second ask's record:
    # 100/10 spent, 200/20 reported.
    it "reports only its OWN round trips when two asks overlap" do
      spent = Lain::Usage.new(input_tokens: 100, output_tokens: 10)
      model = described_class.new(definition:, model: "qwen3:4b",
                                  provider: parking_provider([costing(spent, %({"label":"yes"}))]))

      spends = Sync do
        %w[a b].map do |subject|
          Async do
            model.ask(subject:).await
            model.usage
          end
        end.map(&:wait)
      end

      expect(spends.map { |spend| spend[:input_tokens] }).to eq([100, 100])
    end
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
      backend = Struct.new(:summarizer_provider, :summarizer_model, :summarizer_max_tokens, :summarizer_options,
                           :journal) do
        def summarizer_provider(queue: true) = self[:summarizer_provider] # rubocop:disable Lint/UnusedMethodArgument
      end.new(provider, model, max_tokens, {}, Lain::Channel::Null::INSTANCE)
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

    # The thinking switch is the TIER's, so it rides every oracle on this arm
    # and not only the secret-read judge: this is the summarizer's own
    # construction path, and the handoff tier is built the same way.
    # `--summarizer-provider ollama` with a thinking model is a changed wire.
    it "asks the summarizer's own tier not to think, at the wire" do
      transport = OllamaWire.queue_transport([summary_reply(%({"summary":"three files"}))])
      oracle = summarizer_oracle(Lain::Provider::Ollama.new(transport:), model: "qwen3-coder:30b")

      Sync { oracle.ask(source:).await }

      expect(transport.calls.last[:think]).to be(false)
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
