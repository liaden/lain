# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

# The `bench memory-sweep` door, real Thor parser and real entry point, with the Anthropic API behind
# WebMock: nothing leaves.
load File.expand_path("../../../exe/lain", __dir__) unless defined?(LainCLI::Bench)

RSpec.describe "lain bench memory-sweep" do
  let(:fixture) { File.expand_path("../../fixtures/bench/memory_sweep/fixture.yml", __dir__) }
  let!(:counted) do
    stub_request(:post, "https://api.anthropic.com/v1/messages/count_tokens")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: JSON.generate("input_tokens" => 500))
  end
  let!(:sent) { stub_request(:post, "https://api.anthropic.com/v1/messages") }

  def run(*argv)
    out = StringIO.new
    err = StringIO.new
    original = [$stdout, $stderr, $stdin]
    $stdout = out
    $stderr = err
    $stdin = StringIO.new
    exited = begin
      with_env("ANTHROPIC_API_KEY" => "sk-command-spec") { LainCLI::Bench.start(["memory-sweep", *argv]) }
      nil
    rescue SystemExit => e
      e
    end
    [out.string, err.string, exited]
  ensure
    $stdout, $stderr, $stdin = original
  end

  it "prints the preflight and, with no terminal and no --yes, exits non-zero having sent no paid request" do
    out, err, exited = run(fixture)

    expect(out).to include("Live preflight", "total: $")
    expect(err).to include("no paid request was sent")
    expect(exited&.status).to be_positive
    expect(counted).to have_been_requested.at_least_once
    expect(sent).not_to have_been_requested
  end

  it "exits non-zero naming a fixture with no probes" do
    Dir.mktmpdir("memory-sweep-command") do |dir|
      path = File.join(dir, "empty.yml")
      File.write(path, YAML.load_file(fixture).merge("probes" => []).to_yaml)

      _, err, exited = run(path)

      expect(err).to include(path)
      expect(exited&.status).to be_positive
      expect(sent).not_to have_been_requested
    end
  end
end
