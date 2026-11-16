# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"

# The `bench compaction-sweep` door onto Bench::CLI#compaction_sweep_report. The command is a flag
# parser, so what is under test is which flags it declares and what each one hands the entry point.
# bin/qa-lain is loaded, not run, the way spec/lain/bench/arms_command_spec.rb loads it.
load File.expand_path("../../../bin/qa-lain", __dir__) unless defined?(QALain::Bench)

RSpec.describe "qa-lain bench compaction-sweep" do
  let(:command) { QALain::Bench.commands.fetch("compaction_sweep") }
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
    exited = begin
      QALain::Bench.start(["compaction-sweep", *argv])
      nil
    rescue SystemExit => e
      e
    end
    [out.string, err.string, exited]
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

  # The real entry point and the real Anthropic provider, behind WebMock: nothing leaves.
  describe "under --live" do
    let(:tmp) { Dir.mktmpdir("live-command") }
    let(:journal) { File.join(tmp, "live.ndjson") }
    let(:planted) { File.expand_path("../../fixtures/compaction/planted/one.ndjson", __dir__) }

    before do
      allow(Lain::Bench::CLI).to receive(:new).and_call_original
      stub_request(:post, "https://api.anthropic.com/v1/messages/count_tokens")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("input_tokens" => 500))
    end

    after { FileUtils.rm_rf(tmp) }

    def replies(usage: Lain::Usage.new(input_tokens: 10, output_tokens: 5))
      done = Lain::Response.new(content: [{ "type" => "text", "text" => "done" }], stop_reason: :end_turn,
                                model: "claude-haiku-5-5", usage:)
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, headers: { "Content-Type" => "text/event-stream" }, body: AnthropicSSE.body(done))
    end

    def live_run(*flags)
      original = $stdin
      $stdin = StringIO.new
      with_env("ANTHROPIC_API_KEY" => "sk-command-spec") do
        run(planted, "--arms", "elide", "--live", "claude-haiku-5-5", "--journal", journal, *flags)
      end
    ensure
      $stdin = original
    end

    it "prints the preflight and, with no terminal and no --yes, exits non-zero having sent no paid request" do
      sent = replies

      out, err, exited = live_run

      expect(out).to include("Live preflight", "total: $")
      expect(out).not_to include("spend about")
      expect(err).to include("no paid request was sent")
      expect(exited&.status).to be_positive
      expect(sent).not_to have_been_requested
    end

    it "prints the table and exits non-zero, naming the lane and the error, when a lane raises a defect" do
      replies
      broken = instance_double(Lain::Bench::LiveReplay)
      allow(broken).to receive(:replay).and_raise(NoMethodError, "undefined method 'fetch' for nil")
      allow(Lain::Bench::LiveReplay).to receive(:new).and_return(broken)

      out, err, exited = live_run("--yes")

      expect(out + err).to include("requests sent", "stopped: NoMethodError")
      expect(err.lines.grep(/\S/).last).to match(/elide.*one\.ndjson.*NoMethodError.*fetch/)
      expect(exited&.status).to be_positive
    end

    it "prints the table and exits 0 when a lane stops at its dollar ceiling" do
      replies(usage: Lain::Usage.new(input_tokens: 2_000_000, output_tokens: 0))

      out, err, exited = live_run("--yes")

      expect(out).to include("requests sent", "ceiling is")
      expect(err).to be_empty
      expect(exited).to be_nil
    end
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
