# frozen_string_literal: true

require "tmpdir"

# The session header's run fields, gathered from the backend a chat resolved
# and the project it runs in.
RSpec.describe Lain::CLI::Wiring::Header do
  subject(:header) { described_class.new(project: throwaway_project(@root), paths:) }

  around do |example|
    Dir.mktmpdir("wiring-header") do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  let(:paths) { Lain::Paths.new(env: { "HOME" => "/home/tester", "XDG_CONFIG_HOME" => File.join(@root, "xdg") }) }
  let(:toolset) { CoreGraph.toolset }
  let(:backend) do
    Lain::CLI::Backend.new({ provider: "ollama", model: nil, max_tokens: 64, effort: "low" }, root: @root)
  end

  let(:arms) { Lain::CLI::Arms.from({}) }

  it "gathers the backend's profile, compaction section and middleware, and the arms, as the header sections" do
    expect(header.fields(backend, toolset, arms).fetch(:sections))
      .to have_attributes(profile: backend.run_profile.to_header, compaction: backend.compaction_header,
                          middleware: backend.middleware.to_header, arms: arms.to_header)
  end

  it "records the summarizer tier's provider and model" do
    backend = Lain::CLI::Backend.new({ provider: "ollama", max_tokens: 64, summarizer_provider: "anthropic",
                                       summarizer_model: "claude-haiku-5-5" }, root: @root)

    expect(header.fields(backend, toolset, arms).fetch(:sections).summarizer)
      .to eq("provider" => "anthropic", "model" => "claude-haiku-5-5")
  end

  it "builds the context once, and records its effort in the provenance" do
    allow(backend).to receive(:context).and_call_original
    fields = header.fields(backend, toolset, arms)

    expect([fields.fetch(:context).effort, fields.fetch(:sections).provenance.dig("provenance", "effort")])
      .to eq(%w[low low])
    expect(backend).to have_received(:context).once
  end

  it "records the run's provenance in the project, over the toolset" do
    expect(header.fields(backend, toolset, arms).fetch(:sections).provenance.fetch("provenance"))
      .to include("root" => @root, "cwd" => @root, "home" => "/home/tester", "tool_surface" => toolset.digest)
  end

  describe "the weights" do
    let(:weights) { Lain::Provider::ModelIdentity.new(digest: "sha256:abc", quant: "Q4_K_M") }

    def provenance_with(identity)
      provider = Lain::Provider::Mock.new
      allow(provider).to receive(:model_identity).with(backend.model).and_return(identity)
      allow(backend).to receive(:provider).and_return(provider)
      header.fields(backend, toolset, arms).fetch(:sections).provenance.fetch("provenance")
    end

    it "asks the backend's provider about the backend's model" do
      expect(provenance_with(weights).fetch("weights")).to eq(weights.to_h.transform_keys(&:to_s))
    end

    it "records none for a provider that states none" do
      expect(provenance_with(nil)).not_to have_key("weights")
    end
  end
end
