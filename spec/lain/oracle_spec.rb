# frozen_string_literal: true

# T2: an Oracle is a content-addressed question -- a template, the typed answer
# schema its reply is validated against, and which tier answers it. This spec
# pins the Definition value object: rendering the question purely, validating an
# answer through the schema, and a digest that covers all three fields.
RSpec.describe Lain::Oracle::Definition do
  # A tiny typed answer schema, reused across the oracle specs.
  let(:schema) do
    Class.new(Lain::Tool::Input) do
      field :label, :string, required: true, description: "the verdict label"
      field :score, :float, description: "confidence in 0..1"
      validates :label, inclusion: { in: %w[yes no] }
    end
  end

  let(:template) { %(Is <%= render("subject") %> relevant?) }

  def definition(template: self.template, schema: self.schema, tier: :model)
    described_class.new(template:, schema:, tier:)
  end

  describe "#render (the question, rendered purely)" do
    it "injects the named inputs as slot values" do
      expect(definition.render(subject: "aspirin")).to eq("Is aspirin relevant?")
    end

    it "refuses an impure template rather than resolving it silently" do
      expect { definition(template: %(<%= Time.now %>)).render }
        .to raise_error(Lain::Prompt::ImpureSlot)
    end
  end

  describe "#answer (validating a raw answer through the schema)" do
    it "resolves to the coerced typed answer" do
      answer = Sync { definition.answer("label" => "yes", "score" => "0.8").await }

      expect(answer.label).to eq("yes")
      expect(answer.score).to eq(0.8)
    end

    it "raises loudly when the schema rejects the answer, producing no default" do
      expect { Sync { definition.answer("label" => "maybe").await } }
        .to raise_error(Lain::Oracle::InvalidAnswer)
    end

    # An unexpected extra key is a common LLM structured-output failure. It must
    # land in the SAME exception family as every other malformed answer, so a
    # replay/failure-counting rescue of InvalidAnswer cannot silently miss it.
    it "raises InvalidAnswer (not a bare Tool::InvalidInput) for an unexpected extra key" do
      expect { definition.answer("label" => "yes", "bogus" => "x") }
        .to raise_error(Lain::Oracle::InvalidAnswer)
    end

    it "returns a Promise (awaiting parks the fiber)" do
      expect(definition.answer("label" => "yes")).to be_a(Lain::Promise)
    end
  end

  # A Definition is a deeply frozen value object -- the mechanical statement that
  # it carries no reachable mutable state, so it can cross a Ractor boundary.
  it "is Ractor.shareable?" do
    expect(Ractor.shareable?(definition)).to be(true)
  end

  # ---- Scenario: the definition is content-addressed and deterministic -------

  describe "#digest" do
    it "is stable across two computations" do
      one = definition
      expect(one.digest).to eq(one.digest)
    end

    it "covers the template" do
      expect(definition.digest).not_to eq(definition(template: "different?").digest)
    end

    it "covers the tier" do
      expect(definition(tier: :model).digest).not_to eq(definition(tier: :heuristic).digest)
    end

    it "covers the schema" do
      other = Class.new(Lain::Tool::Input) do
        field :label, :string, required: true, description: "a different shape"
      end
      expect(definition.digest).not_to eq(definition(schema: other).digest)
    end
  end
end
