# frozen_string_literal: true

RSpec.describe Lain::CLI::RunProfile do
  def typed(**options) = described_class.from_options(options)

  def recorded(**fields)
    header = Lain::SessionRecord.header(context: Lain::Context.new(model: fields.fetch(:model, "qwen3:4b"),
                                                                   max_tokens: 16),
                                        toolset: Lain::Toolset.new,
                                        profile: typed(**fields.except(:model)).to_header)
    described_class.from_header(JSON.parse(JSON.generate(header)))
  end

  describe ".from_options" do
    it "counts as typed exactly the fields the options carry a value for" do
      profile = typed(provider: "ollama", model: nil, num_batch: 2048, temperature: 0.2)

      expect(profile.typed).to eq(%i[provider num_batch])
      expect(profile.to_options).to eq(provider: "ollama", model: nil, api_base: nil, num_ctx: nil, num_batch: 2048)
    end

    it "refuses a typed name that is not one of its fields" do
      expect do
        described_class.new(provider: nil, model: nil, api_base: nil, num_ctx: nil, num_batch: nil,
                            typed: [:temperature])
      end.to raise_error(ArgumentError, /temperature/)
    end

    it "is deeply frozen, so it can be shared as a value" do
      expect(Ractor.shareable?(typed(provider: +"ollama", api_base: +"http://127.0.0.1:11434"))).to be(true)
    end
  end

  describe "#with_defaults" do
    it "fills the fields nobody typed, and leaves a typed one alone" do
      profile = typed(provider: "ollama-cloud").with_defaults(provider: "ollama", model: "qwen3:4b", num_ctx: nil)

      expect(profile.provider).to eq("ollama-cloud")
      expect(profile.model).to eq("qwen3:4b")
      expect(profile.typed).to eq(%i[provider])
    end
  end

  describe "#over, the recorded layer" do
    let(:recording) { recorded(provider: "ollama", model: "qwen3:4b", api_base: "http://127.0.0.1:11434", num_batch: 2048) }

    it "takes every untyped field from the recording, over what the environment said" do
      profile = typed.with_defaults(provider: "anthropic", model: "env-model", api_base: nil).over(recording)

      expect(profile.to_options).to eq(provider: "ollama", model: "qwen3:4b", api_base: "http://127.0.0.1:11434",
                                       num_ctx: nil, num_batch: 2048)
    end

    # The order is per field: a field the header did not record is not a
    # recorded value, so the environment still answers it.
    it "keeps the environment's answer for a field the recording left unset" do
      profile = typed.with_defaults(provider: "anthropic", num_ctx: 8192).over(recording)

      expect(profile).to have_attributes(provider: "ollama", num_ctx: 8192, num_batch: 2048)
    end

    it "keeps a typed field over the recording" do
      profile = typed(num_batch: 512).over(recording)

      expect(profile.num_batch).to eq(512)
      expect(profile.provider).to eq("ollama")
    end

    # A recorded model, endpoint and runner knobs belong to the recorded
    # provider: carried onto another one, an ollama model id reaches Anthropic.
    it "takes nothing from a recording made on a provider the human typed away from" do
      profile = typed(provider: "anthropic").with_defaults(model: nil, api_base: nil).over(recording)

      expect(profile.to_options).to eq(provider: "anthropic", model: nil, api_base: nil, num_ctx: nil, num_batch: nil)
    end

    it "changes nothing over a header that recorded no profile" do
      profile = typed.with_defaults(provider: "anthropic").over(described_class.from_header({ "model" => "m" }))

      expect(profile.provider).to eq("anthropic")
      expect(profile.model).to be_nil
    end
  end

  describe "#to_header and .from_header" do
    it "writes the provider and the endpoint fields, and no key for an unset one" do
      expect(typed(provider: "ollama", model: "ignored", num_ctx: 8192).to_header)
        .to eq("provider" => "ollama", "num_ctx" => 8192)
    end

    it "reads the model back from the header's own model field" do
      expect(recorded(provider: "ollama", model: "qwen3:8b").model).to eq("qwen3:8b")
    end

    it "is unrecorded for a header with no provider" do
      expect(described_class.from_header({ "model" => "m" })).not_to be_recorded
    end
  end
end
