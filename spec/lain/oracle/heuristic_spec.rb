# frozen_string_literal: true

# T2: the model-free oracle tier. A pure predicate decides the answer locally and
# it is validated through the SAME typed schema as the model tier, so a caller
# cannot tell which tier answered from the answer's shape -- and no provider is
# wired at all.
RSpec.describe Lain::Oracle::Heuristic do
  let(:schema) do
    Class.new(Lain::Tool::Input) do
      field :label, :string, required: true, description: "the verdict label"
      field :score, :float, description: "confidence in 0..1"
      validates :label, inclusion: { in: %w[yes no] }
    end
  end

  let(:definition) do
    Lain::Oracle::Definition.new(template: "unused by the heuristic", schema:, tier: :heuristic)
  end

  # ---- Scenario: the heuristic tier needs no model --------------------------

  it "returns a validated answer through the identical interface, with no provider wired" do
    oracle = described_class.new(
      definition:,
      predicate: ->(inputs) { { "label" => inputs[:n] > 5 ? "yes" : "no", "score" => 1.0 } }
    )

    answer = Sync { oracle.ask(n: 10).await }

    expect(answer.label).to eq("yes")
    expect(answer.score).to eq(1.0)
  end

  it "raises loudly when the predicate's answer fails the schema" do
    oracle = described_class.new(definition:, predicate: ->(_inputs) { { "label" => "maybe" } })

    expect { Sync { oracle.ask(n: 1).await } }.to raise_error(Lain::Oracle::InvalidAnswer)
  end

  it "returns a Promise, matching the model tier's interface" do
    oracle = described_class.new(definition:, predicate: ->(_inputs) { { "label" => "no" } })

    expect(oracle.ask(n: 1)).to be_a(Lain::Promise)
  end
end
