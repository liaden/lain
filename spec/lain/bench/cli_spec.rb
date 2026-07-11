# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "lain/bench/cli"

require "lain/bench/session"
require "lain/bench/variance_fixtures"
require "lain/provider/mock"
require "lain/response"
require "lain/usage"

# Bench::CLI is ALL of `exe/lain bench`'s assembly: exe/lain only parses flags,
# calls these methods, and `say`s the returned Strings. Every refused input is
# a {Lain::Error} -- {CLI::Refusal} for the user's own mistakes, with the path
# context only this layer still holds, plus Session::Corrupt and the key gate
# -- so the exe rescues Lain::Error ALONE and a programmer bug's ArgumentError
# keeps its backtrace. Nothing here rescues for the user, nothing here prints.
RSpec.describe Lain::Bench::CLI do
  fixture_dir = File.expand_path("../../fixtures/sessions/variance", __dir__)

  subject(:cli) { described_class.new }

  # The whole point of the taxonomy: exe/lain rescues Lain::Error only, so a
  # refusal must BE one, and a bare ArgumentError must stay a loud bug.
  it "classes every bench refusal under Lain::Error" do
    expect(described_class::Refusal).to be < Lain::Error
    expect(described_class::MissingAPIKey).to be < Lain::Error
  end

  describe "#variance_report" do
    it "assembles the Variance report over every *.ndjson under a directory" do
      report = cli.variance_report([fixture_dir])
      expect(report).to start_with("Variance — 3 recordings")
      expect(report).to include("== Determinism", "== Divergence", "== Distribution ==")
    end

    it "returns a String and writes nothing to stdout or stderr" do
      expect { cli.variance_report([fixture_dir]) }.not_to output.to_stdout
      expect { cli.variance_report([fixture_dir]) }.not_to output.to_stderr
    end

    it "loads a directory's sessions in sorted filename order" do
      sorted = Dir.children(fixture_dir).sort.map { |name| File.join(fixture_dir, name) }
      expect(cli.variance_report([fixture_dir])).to eq(cli.variance_report(sorted))
    end

    it "converts Variance's n>=2 guard into a Refusal naming the sources" do
      expect { cli.variance_report([File.join(fixture_dir, "one.ndjson")]) }
        .to raise_error(described_class::Refusal, /one\.ndjson.*at least two/m)
    end

    # A typo'd or empty directory must not fall through to "needs at least two
    # recordings" -- the experimenter typed a directory, so name the directory.
    it "refuses a directory holding no *.ndjson sessions, naming the directory" do
      Dir.mktmpdir do |tmp|
        expect { cli.variance_report([tmp]) }
          .to raise_error(described_class::Refusal, /#{Regexp.escape(tmp)}/)
      end
    end

    # Dir.glob would read "run[1]" as a character class and match nothing; a
    # directory's name must never be parsed as a pattern.
    it "loads a directory whose name carries glob metacharacters" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "run[1]")
        FileUtils.mkdir(dir)
        Dir.children(fixture_dir).each { |name| FileUtils.cp(File.join(fixture_dir, name), dir) }
        expect(cli.variance_report([dir])).to start_with("Variance — 3 recordings")
      end
    end

    # DryReplay's 1:1 guard fires while Variance CONSTRUCTS, long after the
    # paths are gone -- so this layer probes each recording as it loads and
    # names the one file to regenerate, not the whole directory.
    it "refuses an orphan-baseline recording as a Refusal naming the file" do
      Dir.mktmpdir do |tmp|
        FileUtils.cp(File.join(fixture_dir, "one.ndjson"), tmp)
        bytes = File.read(File.join(fixture_dir, "two.ndjson"))
        orphan = bytes.each_line.find { |line| line.include?("request_sent") }
        File.write(File.join(tmp, "two.ndjson"), bytes + orphan)
        expect { cli.variance_report([tmp]) }
          .to raise_error(described_class::Refusal, /two\.ndjson.*baseline/m)
      end
    end

    # Corrupt's own message names a digest; only this layer still holds the
    # path, and an experimenter with a directory of n sessions needs to know
    # WHICH file to regenerate.
    it "lets Session::Corrupt raise on a tampered file, naming the file" do
      Dir.mktmpdir do |tmp|
        FileUtils.cp(File.join(fixture_dir, "one.ndjson"), tmp)
        forged = File.read(File.join(fixture_dir, "two.ndjson")).sub("aspirin", "forged!")
        File.write(File.join(tmp, "two.ndjson"), forged)
        expect { cli.variance_report([tmp]) }
          .to raise_error(Lain::Bench::Session::Corrupt, /two\.ndjson/)
      end
    end

    it "refuses a missing session file with a Refusal, not a raw ENOENT" do
      expect do
        cli.variance_report([File.join(fixture_dir, "absent.ndjson"), File.join(fixture_dir, "one.ndjson")])
      end.to raise_error(described_class::Refusal, /no session file/)
    end
  end

  describe "#record" do
    let(:usage) { Lain::Usage.new(input_tokens: 120, output_tokens: 30) }
    # The last mock response repeats once exhausted, so one script drives
    # every run of the sweep.
    let(:provider) do
      Lain::Provider::Mock.new(responses: [
                                 Lain::Response.new(content: [{ "type" => "text", "text" => "325-650 mg q4h" }],
                                                    stop_reason: :end_turn, usage: usage,
                                                    model: "claude-sonnet-4-6")
                               ])
    end

    def write_taskfile(dir)
      File.join(dir, "task.txt").tap do |path|
        File.write(path, "what is the aspirin dosing?\n\n  \n")
      end
    end

    it "records n loadable sessions through the injected provider, one numbered file per run" do
      Dir.mktmpdir do |tmp|
        out = File.join(tmp, "sessions")
        paths = cli.record(taskfile: write_taskfile(tmp), runs: 2, out: out,
                           model: "claude-sonnet-4-6", provider: provider)

        expect(paths).to eq([File.join(out, "1.ndjson"), File.join(out, "2.ndjson")])
        recordings = paths.map { |path| Lain::Bench::Session.load(path) }
        expect(recordings.map { |recording| recording.timeline.to_a.map(&:role) })
          .to all(eq(%w[user assistant]))
      end
    end

    it "asks one prompt per non-blank task file line, per run" do
      Dir.mktmpdir do |tmp|
        cli.record(taskfile: write_taskfile(tmp), runs: 2, out: File.join(tmp, "sessions"),
                   model: "claude-sonnet-4-6", provider: provider)
        expect(provider.call_count).to eq(2)
        expect(provider.requests.map { |request| request.messages.size }).to all(eq(1))
      end
    end

    it "records sessions Variance can report over" do
      Dir.mktmpdir do |tmp|
        out = File.join(tmp, "sessions")
        cli.record(taskfile: write_taskfile(tmp), runs: 2, out: out,
                   model: "claude-sonnet-4-6", provider: provider)
        expect(cli.variance_report([out])).to include("== Distribution ==")
      end
    end

    # The mirror image of the fixtures' idempotence: fixtures REPLACE because
    # they are scripted and free, but a recorded session cost real money, so
    # an occupied path REFUSES -- Journal.open appends, and a second header in
    # one file would destroy both sweeps' loadability.
    it "refuses to overwrite an existing session file, leaving the recorded bytes untouched" do
      Dir.mktmpdir do |tmp|
        out = File.join(tmp, "sessions")
        record = -> { cli.record(taskfile: write_taskfile(tmp), runs: 2, out: out, provider: provider) }
        before = record.call.map { |path| File.binread(path) }

        expect { record.call }.to raise_error(described_class::Refusal, /already exists/)
        expect(Dir.children(out).sort.map { |name| File.binread(File.join(out, name)) }).to eq(before)
      end
    end

    # A money-spending command must not read `-n 0` as instant success.
    it "refuses a run count below one" do
      Dir.mktmpdir do |tmp|
        expect { cli.record(taskfile: write_taskfile(tmp), runs: 0, out: tmp, provider: provider) }
          .to raise_error(described_class::Refusal, /at least one run/)
      end
    end

    # Integer(2.5) truncates to 2 -- on a money-spending sweep, `-n 2.5` must
    # refuse rather than quietly record fewer runs than typed.
    it "refuses a fractional run count rather than truncating it" do
      Dir.mktmpdir do |tmp|
        expect { cli.record(taskfile: write_taskfile(tmp), runs: 2.5, out: tmp, provider: provider) }
          .to raise_error(described_class::Refusal, /whole number/)
      end
    end

    it "refuses a missing task file with a Refusal, not a raw ENOENT" do
      Dir.mktmpdir do |tmp|
        expect { cli.record(taskfile: File.join(tmp, "absent.txt"), runs: 2, out: tmp, provider: provider) }
          .to raise_error(described_class::Refusal, /no task file/)
      end
    end

    it "refuses a task file with no prompts" do
      Dir.mktmpdir do |tmp|
        blank = File.join(tmp, "task.txt")
        File.write(blank, "\n \n")
        expect { cli.record(taskfile: blank, runs: 2, out: tmp, provider: provider) }
          .to raise_error(described_class::Refusal, /no prompts/)
      end
    end

    # The default wiring builds the REAL provider and spends money, so it is
    # key-gated up front; an injected provider is the caller's own liability
    # (that is how the offline examples above run keyless).
    it "refuses to build the real provider without ANTHROPIC_API_KEY" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return(nil)
      Dir.mktmpdir do |tmp|
        expect { cli.record(taskfile: write_taskfile(tmp), runs: 2, out: tmp) }
          .to raise_error(described_class::MissingAPIKey, /ANTHROPIC_API_KEY/)
      end
    end
  end
end
