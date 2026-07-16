# frozen_string_literal: true

require "tmpdir"

# RunRecorder is the one-run-one-journal-one-file half of `bench record`,
# extracted from Bench::CLI: CLI resolves WHAT to record, this object owns HOW
# one run becomes one loadable session file. cli_spec drives it end to end
# through CLI#record; this pins the unit directly.
RSpec.describe Lain::Bench::CLI::RunRecorder do
  let(:usage) { Lain::Usage.new(input_tokens: 120, output_tokens: 30) }
  let(:provider) { Lain::Provider::Mock.new(responses: [text_response("325-650 mg q4h", usage:)]) }
  let(:context) { Lain::Context.new(model: "claude-sonnet-4-6", max_tokens: 1024) }
  let(:attribution) { Lain::Telemetry::SlotFills.new(digests: {}, fills: {}) }

  subject(:run_recorder) do
    described_class.new(provider:, context:, attribution:, prompts: ["what is the aspirin dosing?"])
  end

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
end
