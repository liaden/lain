# frozen_string_literal: true

require "stringio"

# The `bench compaction-sweep` door onto Bench::CLI#compaction_sweep_report. The command is a flag
# parser, so what is under test is which flags it declares and what each one hands the entry point.
# exe/lain is loaded, not run, the way spec/lain/bench/arms_command_spec.rb loads it.
load File.expand_path("../../../exe/lain", __dir__) unless defined?(LainCLI::Bench)

RSpec.describe "lain bench compaction-sweep" do
  let(:command) { LainCLI::Bench.commands.fetch("compaction_sweep") }
  let(:calls) { [] }
  let(:entry) { instance_double(Lain::Bench::CLI) }

  before do
    allow(Lain::Bench::CLI).to receive(:new).and_return(entry)
    allow(entry).to receive(:compaction_sweep_report) do |**kwargs|
      calls << kwargs
      "the report"
    end
  end

  def kwargs = calls.last

  # The real Thor parser over the real command; a SystemExit is its exit contract, kept as a value.
  def run(*argv)
    out = StringIO.new
    err = StringIO.new
    original = [$stdout, $stderr]
    $stdout = out
    $stderr = err
    begin
      LainCLI::Bench.start(["compaction-sweep", *argv])
    rescue SystemExit => e
      e
    end
    [out.string, err.string]
  ensure
    $stdout, $stderr = original
  end

  it "hands every sweep flag to the entry point under its own name, and says the report" do
    out, = run("a.ndjson", "b.ndjson", "--arms", "elide,eager", "--placement", "bare",
               "--price-as", "claude-sonnet-5-5", "--budget", "500", "--planted", "corpus",
               "--journal", "answers.ndjson", "--recorded", "x.ndjson,y.ndjson")

    expect(kwargs).to eq(journals: %w[a.ndjson b.ndjson], arms: "elide,eager", placements: "bare",
                         price_as: "claude-sonnet-5-5", summarizer: "recorded", budget: 500, planted: "corpus",
                         journal: "answers.ndjson", recorded: "x.ndjson,y.ndjson", backend: nil)
    expect(out).to include("the report")
  end

  it "defaults to every arm, the framed placement, the recorded summarizer and chat's own budget" do
    run("a.ndjson")

    expect(kwargs).to include(arms: Lain::Bench::CompactionSweep::DEFAULT_ARMS.join(","), placements: "framed",
                              price_as: "claude-haiku-5-5", summarizer: "recorded",
                              budget: Lain::CLI::Backend::DEFAULT_BYTE_THRESHOLD, backend: nil)
  end

  it "builds a model backend from the summarizer flags only under the local summarizer" do
    run("a.ndjson", "--summarizer", "local", "--provider", "ollama", "--summarizer-provider", "ollama",
        "--summarizer-model", "qwen3:4b", "--summarizer-max-tokens", "300")

    backend = kwargs.fetch(:backend)
    expect(backend).to be_a(Lain::CLI::Backend)
    expect(backend).to have_attributes(summarizer_model: "qwen3:4b", summarizer_max_tokens: 300)
  end

  it "declares the summarizer endpoint, its budget, and only the model flags that reach a summarizer" do
    expect(command.options.keys).to include(:summarizer_provider, :summarizer_model, :summarizer_max_tokens,
                                            :provider, :api_base, :model, :num_ctx, :num_batch)
    expect(command.options.keys).not_to include(:max_tokens, :temperature, :seed, :keep_alive, :effort,
                                                :confirm_price_tier)
  end

  it "keeps its help text plain" do
    help = command.options.values.map(&:description).join(" ") + command.description

    expect(help).not_to include("—")
  end
end
