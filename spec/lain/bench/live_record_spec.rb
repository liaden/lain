# frozen_string_literal: true

require "tmpdir"

require "lain/bench/cli"

require "lain/bench/session"

# The end-to-end record path: `lain bench record` against the REAL API, twice,
# into a tmpdir -- then the same variance path the fixtures exercise offline.
# Real money on every run, so it is :live-gated (LAIN_LIVE=1 + a key) exactly
# like the other live differentials; spec/support/tags.rb skips it otherwise.
RSpec.describe "lain bench record, live", :live do
  it "records two live sessions of a one-line echo task that load and report variance" do
    Dir.mktmpdir do |tmp|
      taskfile = File.join(tmp, "task.txt")
      File.write(taskfile, "Reply with the single word: pong\n")
      out = File.join(tmp, "sessions")

      # No model: override -- the run exercises RECORD_DEFAULTS' own model,
      # the same one the exe flag defaults to.
      cli = Lain::Bench::CLI.new
      paths = cli.record(taskfile: taskfile, runs: 2, out: out,
                         max_tokens: 64, system: "Reply with one word.")

      expect(paths.size).to eq(2)
      recordings = paths.map { |path| Lain::Bench::Session.load(path) }
      expect(recordings.map { |recording| recording.baseline.size }).to all(be >= 1)

      report = cli.variance_report([out])
      expect(report).to include("== Determinism", "== Divergence", "== Distribution ==")
    end
  end
end
