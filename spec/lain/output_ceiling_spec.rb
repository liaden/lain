# frozen_string_literal: true

RSpec.describe Lain::OutputCeiling do
  def window(tokens, provenance) = Lain::ContextWindow::WindowResolution.new(window_tokens: tokens, provenance:)

  def ceiling(model, resolution = window(1_000_000, :published), **)
    described_class.for(model:, window: resolution, **)
  end

  it "takes an Anthropic 4.6 model's ceiling from the table" do
    expect(ceiling("claude-opus-4-6")).to eq(described_class.new(tokens: 128_000, source: :table))
  end

  it "gives a local ollama model with no table entry its served window" do
    expect(ceiling("qwen3-coder:30b", window(32_768, :probed)))
      .to eq(described_class.new(tokens: 32_768, source: :served_window))
  end

  it "gives an ollama cloud model with no table entry the fallback" do
    expect(ceiling("glm-5.3:cloud", window(1_000_000, :published)))
      .to eq(described_class.new(tokens: 32_768, source: :fallback))
  end

  it "gives a first-party model the table does not carry the same fallback" do
    expect(ceiling("claude-fable-5")).to eq(described_class.new(tokens: 32_768, source: :fallback))
  end

  it "lets a typed flag win over the table" do
    expect(ceiling("claude-opus-4-6", typed: 4_096)).to eq(described_class.new(tokens: 4_096, source: :typed))
  end

  it "never clamps the ceiling to a guessed window" do
    expect(ceiling("qwen3:4b", window(8_192, :guessed))).to eq(described_class.new(tokens: 32_768, source: :fallback))
  end

  # These models refuse a request whose input plus max_tokens passes the
  # window, so a ceiling near the window would 400 a long chat.
  it "keeps 16,384 for the Anthropic models that refuse input plus ceiling over the window" do
    older = %w[claude-opus-4-1-20250805 claude-opus-4-0 claude-opus-4-20250514 claude-sonnet-4-0
               claude-sonnet-4-20250514 claude-3-7-sonnet-20250219]

    expect(older.to_h { |model| [model, ceiling(model).tokens] }).to eq(older.to_h { |model| [model, 16_384] })
  end

  it "gives the 3.5 models their own 8,192 output maximum" do
    expect(%w[claude-3-5-sonnet-20241022 claude-3-5-haiku-20241022].map { |model| ceiling(model) })
      .to all(eq(described_class.new(tokens: 8_192, source: :table)))
  end

  it "answers the same ceiling for every model once typed" do
    typed = described_class.typed(4_096)

    expect(typed.ceiling_for("claude-haiku-4-5")).to eq(typed)
  end

  it "records its value's source for a session header, and nothing when it has none" do
    expect([ceiling("claude-opus-4-6").to_header, described_class.fixed(1_024).to_header])
      .to eq([{ "max_tokens_source" => "table" }, {}])
  end

  describe "a per-model ceiling" do
    it "resolves the ceiling of whichever model it is asked about" do
      per_model = Lain::OutputCeiling::PerModel.new(window: ->(_model) { window(32_768, :probed) })

      expect([per_model.ceiling_for("claude-opus-4-6").tokens, per_model.ceiling_for("qwen3:4b").tokens])
        .to eq([128_000, 32_768])
    end
  end

  it "resolves a name through the shared longest-key rule" do
    expect(described_class.table_tokens("claude-opus-4-5-20251101")).to eq(64_000)
  end
end
