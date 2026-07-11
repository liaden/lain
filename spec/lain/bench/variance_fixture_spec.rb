# frozen_string_literal: true

require "tmpdir"

require "lain/bench/variance_fixtures"

require "lain/bench/session"
require "lain/bench/variance"

# The committed session fixtures under spec/fixtures/sessions/variance are the
# bench's replayable exemplar: three scripted mock recordings of ONE task whose
# response lengths differ, so Variance has real divergence and a real
# distribution to report without a network or a key. Their integrity is the
# format's own (content addressing at load), and their PROVENANCE is code --
# VarianceFixtures.write with a fixed clock -- so this file also proves the
# regeneration is byte-reproducible, the property that makes the fixtures
# reviewable rather than opaque committed bytes.
RSpec.describe "variance session fixtures" do
  fixture_dir = File.expand_path("../../fixtures/sessions/variance", __dir__)

  let(:paths) do
    Lain::Bench::VarianceFixtures::FILES.map { |name| File.join(fixture_dir, "#{name}.ndjson") }
  end
  let(:recordings) { paths.map { |path| Lain::Bench::Session.load(path) } }

  describe "the committed fixtures" do
    it "are three files, each well under the 50KB budget" do
      expect(paths.size).to eq(3)
      paths.each do |path|
        expect(File).to exist(path)
        expect(File.size(path)).to be < 50_000
      end
    end

    it "all load uncorrupted, each a full tool_use-then-end_turn run of the one task" do
      recordings.each do |recording|
        expect(recording.timeline.to_a.map(&:role)).to eq(%w[user assistant user assistant])
        expect(recording.baseline.size).to eq(2)
      end
    end
  end

  describe "Variance over the committed fixtures" do
    let(:report) { Lain::Bench::Variance.new(recordings: recordings).report }

    # One smoke assertion: the report's CONTENT is pinned by the variance spec
    # over live-built objects; this file only proves the fixtures feed it.
    it "reports all three sections" do
      expect(report).to include("== Determinism", "== Divergence", "== Distribution ==")
    end

    it "finds every fixture byte-identical under self dry-replay" do
      expect(report).to include("1: byte-identical", "2: byte-identical", "3: byte-identical")
    end

    # The three scripts share their first model call (same task, same Context,
    # same tools) and differ from the tool_use on, so divergence lands exactly
    # at model call 2 -- fixtures with nothing to diverge would exercise
    # nothing.
    it "locates the scripted divergence at model call 2" do
      expect(report).to include("2: first divergence at model call 2 (messages)")
      expect(report).to include("3: first divergence at model call 2 (messages)")
    end
  end

  # bin/regenerate-session-fixtures is a thin caller of this same method, so
  # regenerating IN PROCESS against a tmpdir proves the committed bytes are
  # exactly what the code writes: fixed clock, fixed model, content-addressed
  # digests -- no timestamp, pid, or ordering leak anywhere in the file.
  describe "regeneration (VarianceFixtures.write)" do
    it "writes files byte-identical to the committed fixtures" do
      Dir.mktmpdir do |tmp|
        written = Lain::Bench::VarianceFixtures.write(dir: tmp)
        written.zip(paths).each do |fresh, committed|
          expect(File.binread(fresh)).to eq(File.binread(committed))
        end
      end
    end

    # Journal.open appends; a regeneration that appended instead of replacing
    # would double the file on the second run and corrupt the fixtures.
    it "is idempotent: writing twice into the same directory yields the same bytes" do
      Dir.mktmpdir do |tmp|
        first = Lain::Bench::VarianceFixtures.write(dir: tmp).map { |path| File.binread(path) }
        second = Lain::Bench::VarianceFixtures.write(dir: tmp).map { |path| File.binread(path) }
        expect(second).to eq(first)
      end
    end
  end
end
