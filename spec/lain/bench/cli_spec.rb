# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# Answers every `git` the worktree backend shells out with success, recording
# the argv. This spec's claim is WHICH backend reaches the arms, not what git
# does with a checkout -- spec/lain/cli/isolation_backend_spec.rb runs the real
# thing -- so faking the subprocess keeps an arm run off the filesystem.
class BenchArmShells
  Fake = Struct.new(:argv, :exitstatus, :stderr, :stdout) do
    def run_command = self
  end

  def initialize
    @calls = []
  end

  attr_reader :calls

  def call(*argv, **)
    @calls << argv
    Fake.new(argv, 0, "", "")
  end
end

# Records the isolation backend the {Lain::Arm::Driver} hands each `#run` and
# then IS the control arm: the lease lifecycle under observation is
# {Lain::Arm::SingleThread}'s own acquire/release, not a mock of it.
#
# `isolation:` is REQUIRED here, unlike on every real arm. Re-declaring the
# base's `NoIsolation` default would let this arm supply the very value the
# spec then credits the DRIVER with, so a driver that stopped passing
# `isolation:` at all would still read as one defaulting to NoIsolation.
# Required, that driver is a loud ArgumentError instead.
class IsolationRecordingArm < Lain::Arm::SingleThread
  def initialize(name:, instrument: Lain::Arm::Instrument.new(clock: -> { 0.0 }))
    super
    @isolations = []
  end

  attr_reader :isolations

  def run(task, isolation:, **rest)
    @isolations << isolation
    super
  end
end

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

  describe "#sweep_report" do
    it "returns the five-arm retrieval report as a String, without printing" do
      report = nil
      # One build serves all three assertions -- a sweep is ~0.3s, and the
      # output matcher runs its block anyway, so silence and content are the
      # same observation. (Only the frontend may print; see
      # spec/output_discipline_spec.rb for the whole-tree guarantee.)
      expect { report = cli.sweep_report(k: 5) }.to output("").to_stdout.and output("").to_stderr
      expect(report).to include("manifest").and include("bm25").and include("vector")
        .and include("hybrid").and include("graph")
    end

    it "is deterministic across calls" do
      expect(cli.sweep_report(k: 5)).to eq(cli.sweep_report(k: 5))
    end

    # Refusal parity with record's --n: user input refuses in the experimenter's
    # vocabulary through the exe's `rescue Lain::Error`, never a bare
    # ArgumentError backtrace.
    it "refuses a non-positive k with a Refusal, not a deep ArgumentError" do
      expect { cli.sweep_report(k: 0) }.to raise_error(described_class::Refusal, /whole number|at least/)
    end

    it "refuses a fractional k rather than silently truncating recall@2.5 to recall@2" do
      expect { cli.sweep_report(k: 2.5) }.to raise_error(described_class::Refusal, /whole number/)
    end
  end

  # An arm run leases its workers from the SAME `--isolation` resolver the chat
  # fleet uses, so a backend name means one thing across commands -- and the
  # resolved backend has to reach EVERY arm, or the comparison is between arms
  # that ran under different confinement.
  describe "#arm_report" do
    let(:spawn_seam) do
      lambda do |journal:|
        Lain::Agent.new(
          provider: Lain::Provider::Mock.new(
            responses: [text_response("done", model: "claude-sonnet-4",
                                              usage: Lain::Usage.new(input_tokens: 100, output_tokens: 20))]
          ),
          toolset: Lain::Toolset.new([]),
          context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 256),
          journal:
        )
      end
    end

    let(:grader) do
      Lain::Grader::Fixture.new("settled") do |f|
        f.check("committed an assistant turn") { |timeline| timeline.to_a.map(&:role).include?("assistant") }
      end
    end

    let(:arms) { [IsolationRecordingArm.new(name: "arm-a"), IsolationRecordingArm.new(name: "arm-b")] }
    let(:tasks) { ["procedural task", "another task"] }

    # What every arm was handed, across every task in the suite.
    def isolations = arms.flat_map(&:isolations)

    it "returns the driver's report as a String, without printing" do
      report = nil
      expect { report = cli.arm_report(arms, tasks:, spawn_seam:, grader:) }
        .to output("").to_stdout.and output("").to_stderr
      expect(report).to include("arm-a").and include("arm-b").and include("grader score")
    end

    it "leaves every arm with Arm::NoIsolation when no isolation option is given" do
      cli.arm_report(arms, tasks:, spawn_seam:, grader:)

      expect(isolations).to all(be(Lain::Arm::NoIsolation))
    end

    # An unset flag is NOT `--isolation none`. Unset keeps the arm-local
    # NoIsolation, whose lease carries NO WorkerEnv at all; `none` resolves a
    # real Isolation::Null that leases the shared process environment. Passing
    # the resolver's own nil-means-default through here would collapse the two,
    # and that distinction is what tells a report's reader whether a run was
    # isolated by a backend or never leased anything.
    it "distinguishes an unset flag from an explicit isolation of none" do
      cli.arm_report(arms, tasks:, spawn_seam:, grader:, isolation: "none")

      expect(isolations).to all(be_a(Lain::Isolation::Null))
      expect(isolations.map { |backend| backend.acquire("arm-a").worker_env }).to all(be_a(Lain::WorkerEnv))
      expect(Lain::Arm::NoIsolation.acquire("arm-a").worker_env).to be_nil
    end

    it "reaches every arm with ONE resolved backend, each arm leasing under its own name" do
      Dir.mktmpdir("lain-bench-project") do |project|
        Dir.mktmpdir("lain-bench-runtime") do |runtime|
          FileUtils.mkdir_p(File.join(project, ".git"))
          journal = Lain::Channel.new
          cli.arm_report(arms, tasks:, spawn_seam:, grader:, isolation: "worktree", root: project, journal:,
                               paths: Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => runtime }),
                               shell_out_factory: BenchArmShells.new)

          leases = journal.drain.grep(Lain::Telemetry::IsolationLease).group_by(&:kind)
          acquired = leases.fetch(:acquired)
          expect(isolations.uniq.size).to eq(1)
          expect(acquired.size).to eq(arms.size * tasks.size)
          expect(acquired.map(&:worker_key).uniq).to contain_exactly("arm-a", "arm-b")
          expect(acquired.map(&:backend).uniq).to eq([Lain::Isolation::Worktree.name])
          # Acquire alone is not the claim: a backend that leaked every lease
          # would satisfy it. The record is a LIFECYCLE, so every acquire the
          # arms took must have a release journaled against it.
          expect(leases.fetch(:released).size).to eq(acquired.size)
        end
      end
    end

    # Forwarding backend options to a resolver that is never called would drop
    # them in silence -- and a caller who passes `journal:` for lease telemetry
    # but no name would get neither the telemetry nor a word about it, while the
    # same key one flag later (`isolation: "none", bogus: 1`) is a loud unknown-
    # keyword ArgumentError. A wiring bug, so it crashes like one.
    it "refuses backend options given with no isolation name, rather than dropping them" do
      expect { cli.arm_report(arms, tasks:, spawn_seam:, grader:, journal: Lain::Channel.new) }
        .to raise_error(ArgumentError, /journal/)
    end

    # Parity with record's unknown --provider: the ONE named Lain error, raised
    # at resolution, so the exe's `rescue Lain::Error` presents it and no arm is
    # dispatched under a backend the operator did not ask for.
    it "raises the one named Lain error on an unknown isolation name" do
      expect { cli.arm_report(arms, tasks:, spawn_seam:, grader:, isolation: "docker") }
        .to raise_error(Lain::CLI::IsolationBackend::Unknown, /docker/)
    end
  end

  describe "#record" do
    let(:usage) { Lain::Usage.new(input_tokens: 120, output_tokens: 30) }

    # The last mock response repeats once exhausted, so one script drives
    # every run of the sweep.
    let(:provider) do
      Lain::Provider::Mock.new(responses: [text_response("325-650 mg q4h", usage:,
                                                                           model: "claude-sonnet-4-6")])
    end

    # The ONE object record now takes for its provider and its Context, built the
    # way exe/lain and every other Backend spec build it: from the flag hash.
    # `max_tokens` is spelled out because Context requires it (`Integer(nil)`
    # raises) and RECORD_DEFAULTS is where the exe's flag reads its own default
    # from, so this is the same number a run gets.
    def backend(**options)
      Lain::CLI::Backend.new(
        { provider: "anthropic", max_tokens: described_class::RECORD_DEFAULTS.fetch(:max_tokens), **options }
      )
    end

    def write_taskfile(dir)
      File.join(dir, "task.txt").tap do |path|
        File.write(path, "what is the aspirin dosing?\n\n  \n")
      end
    end

    it "records n loadable sessions through the injected provider, one numbered file per run" do
      Dir.mktmpdir do |tmp|
        out = File.join(tmp, "sessions")
        paths = cli.record(taskfile: write_taskfile(tmp), runs: 2, out:,
                           backend: backend(model: "claude-sonnet-4-6"), provider:)

        expect(paths).to eq([File.join(out, "1.ndjson"), File.join(out, "2.ndjson")])
        recordings = paths.map { |path| Lain::Bench::Session.load(path) }
        expect(recordings.map { |recording| recording.timeline.to_a.map(&:role) })
          .to all(eq(%w[user assistant]))
      end
    end

    it "asks one prompt per non-blank task file line, per run" do
      Dir.mktmpdir do |tmp|
        cli.record(taskfile: write_taskfile(tmp), runs: 2, out: File.join(tmp, "sessions"),
                   backend: backend(model: "claude-sonnet-4-6"), provider:)
        expect(provider.call_count).to eq(2)
        expect(provider.requests.map { |request| request.messages.size }).to all(eq(1))
      end
    end

    it "records sessions Variance can report over" do
      Dir.mktmpdir do |tmp|
        out = File.join(tmp, "sessions")
        cli.record(taskfile: write_taskfile(tmp), runs: 2, out:,
                   backend: backend(model: "claude-sonnet-4-6"), provider:)
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
        record = -> { cli.record(taskfile: write_taskfile(tmp), runs: 2, out:, backend:, provider:) }
        before = record.call.map { |path| File.binread(path) }

        expect { record.call }.to raise_error(described_class::Refusal, /already exists/)
        expect(Dir.children(out).sort.map { |name| File.binread(File.join(out, name)) }).to eq(before)
      end
    end

    # A money-spending command must not read `-n 0` as instant success.
    it "refuses a run count below one" do
      Dir.mktmpdir do |tmp|
        expect { cli.record(taskfile: write_taskfile(tmp), runs: 0, out: tmp, backend:, provider:) }
          .to raise_error(described_class::Refusal, /at least one run/)
      end
    end

    # Integer(2.5) truncates to 2 -- on a money-spending sweep, `-n 2.5` must
    # refuse rather than quietly record fewer runs than typed.
    it "refuses a fractional run count rather than truncating it" do
      Dir.mktmpdir do |tmp|
        expect { cli.record(taskfile: write_taskfile(tmp), runs: 2.5, out: tmp, backend:, provider:) }
          .to raise_error(described_class::Refusal, /whole number/)
      end
    end

    it "refuses a missing task file with a Refusal, not a raw ENOENT" do
      Dir.mktmpdir do |tmp|
        expect { cli.record(taskfile: File.join(tmp, "absent.txt"), runs: 2, out: tmp, backend:, provider:) }
          .to raise_error(described_class::Refusal, /no task file/)
      end
    end

    it "refuses a task file with no prompts" do
      Dir.mktmpdir do |tmp|
        blank = File.join(tmp, "task.txt")
        File.write(blank, "\n \n")
        expect { cli.record(taskfile: blank, runs: 2, out: tmp, backend:, provider:) }
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
        expect { cli.record(taskfile: write_taskfile(tmp), runs: 2, out: tmp, backend:) }
          .to raise_error(described_class::MissingAPIKey, /ANTHROPIC_API_KEY/)
      end
    end

    # AC2: chat and record resolve providers through the SAME Backend, so an
    # unknown --provider name raises the one named Lain error from either path,
    # never Thor::Error out of lib/.
    it "raises Lain::CLI::UnknownProvider on an unknown --provider name" do
      Dir.mktmpdir do |tmp|
        expect { cli.record(taskfile: write_taskfile(tmp), runs: 2, out: tmp, backend: backend(provider: "gemini")) }
          .to raise_error(Lain::CLI::UnknownProvider, /gemini/)
      end
    end

    # AC1: an ollama temp-0 arm records. The provider is stubbed (money), but
    # the sampler flags ride the Context into Request#extra, so the recorded
    # session HEADER carries them and the recording still replays dry.
    describe "an ollama temp-0 arm" do
      it "records the sampler extra into the session header and replays dry" do
        Dir.mktmpdir do |tmp|
          out = File.join(tmp, "sessions")
          cli.record(taskfile: write_taskfile(tmp), runs: 1, out:, provider:,
                     backend: backend(provider: "ollama", temperature: 0, seed: 7))

          recording = Lain::Bench::Session.load(File.join(out, "1.ndjson"))
          expect(recording.context.extra).to include("temperature" => 0, "seed" => 7)
          expect { recording.dry_replay }.not_to raise_error
        end
      end
    end

    # The orchestrator amendment: bench record owns PS-2 emission. Each recorded
    # journal carries EXACTLY ONE slot_fills record, built from the slots the
    # Backend's context rendered, and Loader#slot_fills reads it back.
    describe "slot attribution (PS-2)" do
      def slot_fills_count(path)
        File.readlines(path).map { |line| JSON.parse(line) }.count { |record| record["type"] == "slot_fills" }
      end

      it "emits exactly one slot_fills record per recorded session" do
        Dir.mktmpdir do |tmp|
          out = File.join(tmp, "sessions")
          paths = cli.record(taskfile: write_taskfile(tmp), runs: 2, out:,
                             backend: backend(model: "claude-sonnet-4-6"), provider:)

          expect(paths.map { |path| slot_fills_count(path) }).to all(eq(1))
        end
      end

      it "records fills Loader#slot_fills reads back as the session's attribution" do
        Dir.mktmpdir do |tmp|
          out = File.join(tmp, "sessions")
          cli.record(taskfile: write_taskfile(tmp), runs: 1, out:,
                     backend: backend(model: "claude-sonnet-4-6"), provider:)

          loader = Lain::Bench::Session::Loader.new(File.foreach(File.join(out, "1.ndjson")))
          expect(loader.slot_fills.digests).not_to be_empty
        end
      end

      # The attribution's one claim is the JOIN: digests["system"] content-
      # addresses the system bytes the request_sent records journal in full
      # (the T9 join-guard idiom). That must hold under --system too -- an
      # override renders INSTEAD of the slots, so a record still carrying the
      # untouched slots' digests would be a coherent-looking lie.
      def journaled_system_text(records)
        payload_system = records.find { |record| record["type"] == "request_sent" }
                                .fetch("payload").fetch("system")
        return payload_system if payload_system.is_a?(String)

        payload_system.map { |block| block.fetch("text") }.join
      end

      it "attributes a --system override so the digest still joins onto the journaled system bytes" do
        Dir.mktmpdir do |tmp|
          out = File.join(tmp, "sessions")
          cli.record(taskfile: write_taskfile(tmp), runs: 1, out:, system: "Reply with one word.",
                     backend: backend(model: "claude-sonnet-4-6"), provider:)

          records = File.readlines(File.join(out, "1.ndjson")).map { |line| JSON.parse(line) }
          slot_fills = records.find { |record| record["type"] == "slot_fills" }
          expect(slot_fills.fetch("digests").fetch("system"))
            .to eq(Lain::Canonical.digest(journaled_system_text(records)))
          expect(slot_fills.fetch("fills").fetch("system")).to eq("Reply with one word.")
        end
      end

      it "attributes the default slot render so the digest joins onto the journaled system bytes" do
        Dir.mktmpdir do |tmp|
          out = File.join(tmp, "sessions")
          cli.record(taskfile: write_taskfile(tmp), runs: 1, out:,
                     backend: backend(model: "claude-sonnet-4-6"), provider:)

          records = File.readlines(File.join(out, "1.ndjson")).map { |line| JSON.parse(line) }
          expect(records.find { |record| record["type"] == "slot_fills" }.fetch("digests").fetch("system"))
            .to eq(Lain::Canonical.digest(journaled_system_text(records)))
        end
      end
    end
  end
end
