# frozen_string_literal: true

# The memory arms' deterministic checks: a stale leak is the old gold answer
# repeated, drift is a substring the fixture names, and neither needs a grader.
RSpec.describe Lain::Bench::MemorySweep do
  # Answers from what the request carries, so an arm that withholds the memory changes the answer.
  let(:fixture_path) { File.expand_path("../../fixtures/bench/memory_sweep/fixture.yml", __dir__) }
  let(:provider_class) do
    Class.new(Lain::Provider::Mock) do
      attr_writer :stale_answer

      def complete(request, **)
        text = request.cache_payload.to_s
        answer = if text.include?("Which port") then @stale_answer || "the service listens on port 9090"
                 elsif text.include?("answer sizes in bytes") then "about 4096 bytes"
                 else "about 4 megabytes"
                 end
        @requests << request
        Lain::Response.new(content: [{ "type" => "text", "text" => answer }], stop_reason: :end_turn,
                           model: "claude-haiku-5-5", usage: Lain::Usage.new(input_tokens: 1000, output_tokens: 100))
      end
    end
  end
  let(:provider) { provider_class.new }
  let(:fixture) { described_class::Fixture.load(fixture_path) }
  let(:sweep) { described_class.new(fixture:, provider:, model: "claude-haiku-5-5") }

  def row(report, arm) = report.lines.find { _1.start_with?(arm) }.split("  ").map(&:strip).reject(&:empty?)

  it "counts a stale leak when an answer repeats the old fact" do
    provider.stale_answer = "the service listens on port 8080"

    expect(row(sweep.report, "memory_on")).to include("1/1")
  end

  it "reads freshness as the fraction of manifest items whose sources are unchanged" do
    expect(row(sweep.report, "memory_on")).to include("0.67")
  end

  it "marks freshness absent for the control, which has no manifest" do
    expect(row(sweep.report, "memory_off")).to include("-")
  end

  it "measures instruction drift in the control and not with the memory" do
    report = sweep.report

    expect(row(report, "memory_off")).to include("1/1")
    expect(row(report, "memory_on")).to include("0/1")
  end

  it "withholds the manifest and the memory tools from the control" do
    sweep.report
    payloads = provider.requests.map { _1.cache_payload.to_s }

    expect(payloads.values_at(0, 1)).to all(include("memory_write", "service-port"))
    expect(payloads.values_at(2, 3)).to all(satisfy { !_1.include?("memory_write") && !_1.include?("service-port") })
  end

  it "puts the instruction to the eager arm's system prompt" do
    sweep.report

    expect(provider.requests.map { _1.cache_payload.to_s }.grep(/after every answer/i)).not_to be_empty
  end

  it "reports each arm's cost per question with an interval beside the stated prior" do
    report = sweep.report

    expect(report).to include("eager write: +15% cost, p 0.015 (scan item 106)")
    expect(described_class::ARMS.map { row(report, _1) }).to all(include(match(/\$\d+\.\d+\.\.\$\d+\.\d+/)))
  end

  it "refuses a fixture with no probes, naming its path" do
    Dir.mktmpdir("memory-sweep") do |dir|
      path = File.join(dir, "empty.yml")
      File.write(path, YAML.load_file(fixture_path).merge("probes" => []).to_yaml)

      expect { described_class::Fixture.load(path) }
        .to raise_error(Lain::Bench::MemorySweep::Fixture::Invalid, /#{Regexp.escape(path)}/)
    end
  end

  describe "when the provider stops a question" do
    def stopping(kind)
      Class.new(provider_class) do
        define_method(:complete) do |request, **|
          @requests << request
          raise Lain::Budget::Exceeded.new("stopped for the spec", kind:)
        end
      end.new
    end

    it "prints the table with the stop in the arm's row, then raises it, and runs the rest of the questions" do
      stopped = stopping(:iterations)

      expect { described_class.new(fixture:, provider: stopped, model: "claude-haiku-5-5").report }
        .to raise_error(Lain::Bench::MemorySweep::Halted, /memory_on.*stopped: stopped for the spec/m)
      expect(stopped.call_count).to eq(6)
    end

    it "runs no later question after a dollar stop" do
      stopped = stopping(:dollars)

      expect { described_class.new(fixture:, provider: stopped, model: "claude-haiku-5-5").report }
        .to raise_error(Lain::Bench::MemorySweep::Halted, /memory_off.*not run: an earlier question passed/m)
      expect(stopped.call_count).to eq(1)
    end
  end

  describe "the preflight" do
    before { allow(provider).to receive(:count_tokens).and_return(1000) }

    def preflight_of(model: "claude-haiku-5-5")
      seen = nil
      described_class.new(fixture:, provider:, model:, confirm: ->(checked) { (seen = checked) && false }).report
    rescue Lain::Bench::CompactionSweep::Live::Declined
      seen
    end

    it "counts a second round trip for the arms with memory tools and none for the control" do
      turns = preflight_of.requests.group_by(&:arm).transform_values { |requests| requests.map(&:turn).uniq.sort }

      expect(turns).to eq("memory_on" => [1, 2], "eager_write" => [1, 2], "memory_off" => [1])
    end

    it "lists the requests over the price tier" do
      allow(provider).to receive(:count_tokens).and_return(150_000)

      expect(preflight_of.report).to include("Over the price tier")
    end

    it "lists none when every request is under it" do
      expect(preflight_of.report).to include("No request crosses its price tier.")
    end
  end

  describe "with a confirmation" do
    before { allow(provider).to receive(:count_tokens).and_return(1000) }

    it "sends nothing when the preflight is declined" do
      declined = described_class.new(fixture:, provider:, model: "claude-haiku-5-5", confirm: ->(_) { false })

      expect { declined.report }.to raise_error(Lain::Bench::CompactionSweep::Live::Declined)
      expect(provider.requests).to be_empty
    end

    it "shows the priced question before it spends" do
      asked = []
      confirm = ->(preflight) { (asked << preflight.question) && false }

      expect { described_class.new(fixture:, provider:, model: "claude-haiku-5-5", confirm:).report }
        .to raise_error(Lain::Bench::CompactionSweep::Live::Declined)
      expect(asked.first).to match(%r{spend about \$\d+\.\d+, capped at \$\d+\.\d+\? \[y/N\]})
    end
  end

  describe Lain::Bench::MemorySweep::Fixture do
    def with_source(path)
      YAML.load_file(fixture_path).merge("sources" => [{ "path" => path, "before" => "a", "after" => "b" }]).to_yaml
    end

    # Yields the path the content was written to, so each example states its own expectation.
    def written(content)
      Dir.mktmpdir("memory-sweep-fixture") do |dir|
        File.join(dir, "bad.yml").tap { File.write(_1, content) }.then { yield _1 }
      end
    end

    {
      "an empty file" => ["", "mapping"],
      "a bare string" => ["just words", "mapping"]
    }.each do |what, (content, pattern)|
      it "refuses #{what}, naming the path" do
        written(content) do |path|
          expect { described_class.load(path) }
            .to raise_error(Lain::Bench::MemorySweep::Fixture::Invalid, /#{Regexp.escape(path)}.*#{pattern}/)
        end
      end
    end

    %w[/etc/hosts ../outside.txt].each do |source|
      it "refuses the source path #{source}" do
        written(with_source(source)) do |path|
          expect do
            described_class.load(path)
          end.to raise_error(Lain::Bench::MemorySweep::Fixture::Invalid, /#{source}.*not inside/)
        end
      end
    end
  end
end
