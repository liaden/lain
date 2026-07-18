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
end
