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

  it "hands on the backend's profile, compaction section and middleware" do
    expect(header.fields(backend, toolset))
      .to include(profile: backend.run_profile, compaction: backend.compaction_header,
                  middleware: backend.middleware)
  end

  it "builds the context once, and records its effort in the provenance" do
    allow(backend).to receive(:context).and_call_original
    fields = header.fields(backend, toolset)

    expect([fields.fetch(:context).effort, fields.fetch(:provenance).effort]).to eq(%w[low low])
    expect(backend).to have_received(:context).once
  end

  it "records the run's provenance in the project, over the toolset" do
    expect(header.fields(backend, toolset).fetch(:provenance))
      .to have_attributes(root: @root, cwd: @root, home: "/home/tester", tool_surface: toolset.digest)
  end
end
