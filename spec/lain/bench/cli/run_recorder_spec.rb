# frozen_string_literal: true

require "tmpdir"

# RunRecorder is the one-run-one-journal-one-file half of `bench record`,
# extracted from Bench::CLI: CLI resolves WHAT to record, this object owns HOW
# one run becomes one loadable session file. cli_spec drives it end to end
# through CLI#record; this pins the unit directly.
RSpec.describe Lain::Bench::CLI::RunRecorder do
  subject(:run_recorder) do
    described_class.new(provider:, context:, attribution:, prompts: ["what is the aspirin dosing?"])
  end

  let(:usage) { Lain::Usage.new(input_tokens: 120, output_tokens: 30) }
  let(:provider) { Lain::Provider::Mock.new(responses: [text_response("325-650 mg q4h", usage:)]) }
  let(:context) { Lain::Context.new(model: "claude-sonnet-4-6", max_tokens: 1024) }
  let(:attribution) { Lain::Telemetry::SlotFills.new(digests: {}, fills: {}) }

  it "writes one loadable session, slot_fills attribution included" do
    Dir.mktmpdir do |tmp|
      path = run_recorder.record(File.join(tmp, "1.ndjson"))

      recording = Lain::Bench::Session.load(path)
      expect(recording.timeline.to_a.map(&:role)).to eq(%w[user assistant])
      expect(recording.baseline).to eq(provider.requests)
    end
  end

  it "refuses an occupied path, leaving the recorded bytes untouched" do
    Dir.mktmpdir do |tmp|
      path = run_recorder.record(File.join(tmp, "1.ndjson"))
      before = File.binread(path)

      expect { run_recorder.record(path) }
        .to raise_error(Lain::Bench::CLI::Refusal, /already exists/)
      expect(File.binread(path)).to eq(before)
    end
  end

  def types_in(path) = File.foreach(path).map { |line| JSON.parse(line)["type"] }

  # One provider serves every run, so what it writes has to follow the run
  # that is recording rather than whichever journal it was built with.
  describe "the provider's own records" do
    let(:current_run) { described_class::CurrentRun.new }
    let(:context) { Lain::Context.new(model: "qwen3:4b", max_tokens: 64) }
    let(:provider) { Lain::Provider::Ollama.new(journal: current_run) }

    def recorder = described_class.new(provider:, context:, attribution:, prompts: ["hi"], current_run:)

    # A stream that stops without its `done` line.
    def stub_unterminated_stream
      stub_request(:post, "http://localhost:11434/api/chat")
        .to_return(status: 200, headers: { "Content-Type" => "application/x-ndjson" },
                   body: "#{JSON.generate("model" => "qwen3:4b", "done" => false,
                                          "message" => { "role" => "assistant", "content" => "par" })}\n")
    end

    it "lands a truncated stream in the file of the run it cut short" do
      stub_unterminated_stream
      Dir.mktmpdir do |tmp|
        path = recorder.record(File.join(tmp, "1.ndjson"))

        expect(types_in(path)).to include("truncated_stream")
      end
    end

    it "writes each run's truncated stream into that run's own file, and nothing between runs" do
      stub_unterminated_stream
      Dir.mktmpdir do |tmp|
        paths = [recorder.record(File.join(tmp, "1.ndjson")), recorder.record(File.join(tmp, "2.ndjson"))]
        current_run << Lain::Telemetry::ProviderRetry.new(attempt: 1, reason: "between runs")

        expect(paths.map { |path| types_in(path).count("truncated_stream") }).to eq([1, 1])
        expect(paths.map { |path| types_in(path) }).to all(satisfy { |types| !types.include?("provider_retry") })
      end
    end

    it "journals each capability the context needs and the provider lacks, once per run file" do
      stub_unterminated_stream
      Dir.mktmpdir do |tmp|
        path = recorder.record(File.join(tmp, "1.ndjson"))

        expect(Lain::Bench::Session.load(path).degraded).to eq(Lain::Capability::DegradedSet.new([:prompt_caching]))
      end
    end
  end

  # A provider that raises `error` on its first call and answers after.
  def refusing_once(error)
    Class.new(Lain::Provider::Mock) do
      define_method(:complete) do |request, **kwargs|
        return super(request, **kwargs) if @refused

        @refused = true
        raise error
      end
    end.new(responses: [text_response("325-650 mg q4h", usage:)])
  end

  def records_in(path) = File.foreach(path).map { |line| JSON.parse(line) }

  # A run whose round trip failed is set aside under a name no reader takes for
  # a recording, and the next run still gets its turn.
  describe "a run whose round trip failed" do
    let(:provider) { refusing_once(Lain::Provider::Ollama::APIError.new("connection refused")) }

    it "renames its partial file aside and says why, in place of the path" do
      Dir.mktmpdir do |tmp|
        said = run_recorder.record(File.join(tmp, "1.ndjson"))

        expect(said).to eq("#{File.join(tmp, "1.failed.ndjson")} " \
                           "(set aside: Lain::Provider::Ollama::APIError: connection refused)")
        expect(Dir.children(tmp)).to eq(["1.failed.ndjson"])
        expect(types_in(File.join(tmp, "1.failed.ndjson"))).not_to include("session")
      end
    end

    it "writes why into the set-aside file, and nothing of the conversation" do
      Dir.mktmpdir do |tmp|
        run_recorder.record(File.join(tmp, "1.ndjson"))

        failure = records_in(File.join(tmp, "1.failed.ndjson")).find { |record| record["type"] == "recording_failed" }
        expect(failure).to include("error_class" => "Lain::Provider::Ollama::APIError",
                                   "message" => "connection refused")
        expect(failure.keys).to contain_exactly("type", "ts", "error_class", "message")
      end
    end

    it "records the next run whole" do
      Dir.mktmpdir do |tmp|
        run_recorder.record(File.join(tmp, "1.ndjson"))

        expect(Lain::Bench::Session.load(run_recorder.record(File.join(tmp, "2.ndjson"))).timeline.to_a.map(&:role))
          .to eq(%w[user assistant])
      end
    end

    {
      "a server error" => -> { Lain::Provider::Ollama::APIStatusError.new("runner stopped", status: 500) },
      "a busy endpoint" => -> { Lain::Provider::Admission::Busy.new("localhost:11434 is busy") },
      "an Anthropic transport error" => -> { Lain::Provider::Anthropic::APIError.new("timed out") }
    }.each do |name, error|
      it "sets aside a run that ended on #{name}" do
        recorder = described_class.new(provider: refusing_once(error.call), context:, attribution:, prompts: ["hi"])
        Dir.mktmpdir do |tmp|
          expect(recorder.record(File.join(tmp, "1.ndjson"))).to include("1.failed.ndjson (set aside:")
        end
      end
    end

    # Never over another file: the name can be taken between the start of the
    # run and its end, by a second sweep into the same directory.
    it "refuses rather than replace a set-aside name taken while the run went on, naming both files" do
      Dir.mktmpdir do |tmp|
        target = File.join(tmp, "1.failed.ndjson")
        sneaky = Class.new(Lain::Provider::Mock) do
          define_method(:complete) do |*|
            File.write(target, "earlier recording\n")
            raise Lain::Provider::Ollama::APIError, "reset"
          end
        end
        recorder = described_class.new(provider: sneaky.new, context:, attribution:, prompts: ["hi"])

        expect { recorder.record(File.join(tmp, "1.ndjson")) }
          .to raise_error(Lain::Bench::CLI::Refusal, /1\.ndjson aside: .*1\.failed\.ndjson already exists/)
        expect(File.read(target)).to eq("earlier recording\n")
      end
    end

    # A leftover set aside by an earlier sweep is that sweep's record, not an
    # occupied session path.
    it "records a run whose set-aside name an earlier sweep left behind" do
      Dir.mktmpdir do |tmp|
        File.write(File.join(tmp, "1.failed.ndjson"), "earlier\n")
        recorder = described_class.new(provider: Lain::Provider::Mock.new(responses: [text_response("ok", usage:)]),
                                       context:, attribution:, prompts: ["hi"])

        expect(recorder.record(File.join(tmp, "1.ndjson"))).to eq(File.join(tmp, "1.ndjson"))
      end
    end
  end

  # Only a failed round trip is a failed recording. Everything else either is
  # the run's own outcome, or would fail every run the same way.
  describe "a run that stops for any other reason" do
    # A model that asks for a tool this toolless run does not have, forever:
    # the loop runs into its iteration ceiling, which is how a budget stops.
    it "records a run the budget stopped, as the recording it is" do
      looping = Lain::Provider::Mock.new(responses: [tool_response(["tu_1", "grep", { "pattern" => "x" }], usage:)])
      recorder = described_class.new(provider: looping, context:, attribution:, prompts: ["hi"])
      Dir.mktmpdir do |tmp|
        path = recorder.record(File.join(tmp, "1.ndjson"))

        expect(path).to eq(File.join(tmp, "1.ndjson"))
        expect(Lain::Bench::Session.load(path).timeline.to_a.count { |turn| turn.role == "assistant" })
          .to eq(Lain::Agent::Budget::DEFAULT_MAX_ITERATIONS)
      end
    end

    {
      "a capability the provider lacks" => -> { Lain::Provider::Unsupported.new("no such capability") },
      "a refused request" => -> { Lain::Provider::Ollama::APIStatusError.new("unauthorized", status: 401) },
      "a bug" => -> { ArgumentError.new("wrong number of arguments") },
      "Ctrl-C" => -> { Interrupt.new }
    }.each do |name, error|
      it "sets the partial file aside and raises on #{name}, so the sweep stops" do
        raised = error.call
        recorder = described_class.new(provider: refusing_once(raised), context:, attribution:, prompts: ["hi"])
        Dir.mktmpdir do |tmp|
          expect { recorder.record(File.join(tmp, "1.ndjson")) }.to raise_error(raised.class)

          expect(Dir.children(tmp)).to eq(["1.failed.ndjson"])
          expect(records_in(File.join(tmp, "1.failed.ndjson")).map { |record| record["error_class"] })
            .to include(raised.class.name)
        end
      end
    end
  end

  # What a recorded run STARTED from. The default is the empty version, and
  # that default is a measurement decision: a sweep that began from whatever
  # the operator's project happened to remember is not comparable with the same
  # sweep a week later.
  describe "the memory a run starts from" do
    def loaded_in(path)
      records_in(path).select { |record| record["type"] == "memory_loaded" }
    end

    it "names the empty version, with no items, when no memory source is given" do
      Dir.mktmpdir do |tmp|
        path = run_recorder.record(File.join(tmp, "1.ndjson"))

        expect(loaded_in(path).size).to eq(1)
        expect(loaded_in(path).first.fetch("version")).to eq(Lain::Memory::ProjectStore.empty.version)
        expect(loaded_in(path).first.fetch("items")).to eq([])
      end
    end

    it "names the project store's version and items when it is given one" do
      Dir.mktmpdir do |tmp|
        store = Lain::Memory::ProjectStore.new(
          project_dir: Lain::ProjectDir.new(root: tmp, paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => tmp,
                                                                                     "HOME" => tmp }))
        )
        store.append(Lain::Memory::Item.new(id: "db-conventions", description: "naming", body: "snake"))
        path = described_class.new(provider:, context:, attribution:, prompts: ["hi"], memory: store)
                              .record(File.join(tmp, "1.ndjson"))

        expect(loaded_in(path).first.fetch("version")).to eq(store.load.version)
        expect(loaded_in(path).first.fetch("items").map { |item| item.fetch("id") }).to eq(["db-conventions"])
      end
    end
  end
end
