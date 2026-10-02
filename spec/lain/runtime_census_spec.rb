# frozen_string_literal: true

require "open3"
require "tmpdir"
require "fileutils"

load File.expand_path("../../bin/runtime-census", __dir__)

# Fixture logs only: a real runtime log is the output of a full suite run.
RSpec.describe RuntimeCensus do
  def log(**files) = files.map { |path, seconds| "#{path}:#{seconds}" }.join("\n")

  # A complete pspec log names every ceilinged file; overrides set particular ones.
  def full_log(**overrides)
    seconds = RuntimeCensus::CEILINGS.keys.to_h { |path| [path, 1.0] }.merge(overrides.transform_keys(&:to_s))
    seconds.map { |path, secs| "#{path}:#{secs}" }.join("\n")
  end

  def logs(*bodies) = bodies.map { |body| RuntimeCensus::Log.parse(body) }

  describe RuntimeCensus::Log do
    it "reads path:seconds lines and ignores the prose rspec writes into the same file" do
      text = <<~LOG
        Run options: exclude {live: true}
        Skipping :ollama specs. Set LAIN_OLLAMA=1 to run them.
        spec/a_spec.rb:1.5
        spec/b_spec.rb:0.25
      LOG

      expect(described_class.parse(text)).to eq("spec/a_spec.rb" => 1.5, "spec/b_spec.rb" => 0.25)
    end

    it "sums a file that appears more than once" do
      expect(described_class.parse("spec/a_spec.rb:1.0\nspec/a_spec.rb:2.0")).to eq("spec/a_spec.rb" => 3.0)
    end
  end

  describe RuntimeCensus::Packing do
    it "simulates the longest-first wall as the busiest worker's total" do
      seconds = { "a" => 6.0, "b" => 5.0, "c" => 4.0, "d" => 3.0 }

      expect(described_class.wall(seconds, 2)).to eq(9.0)
    end

    it "is bounded below by the longest single file however many workers" do
      expect(described_class.wall({ "a" => 7.0, "b" => 1.0 }, 12)).to eq(7.0)
    end

    it "is 0 for no files" do
      expect(described_class.wall({}, 4)).to eq(0.0)
    end
  end

  describe ".check" do
    let(:ceilings) { { "spec/slow_spec.rb" => 10 }.freeze }
    let(:over) { log("spec/slow_spec.rb": 11.0, "spec/ok_spec.rb": 1.0) }
    let(:under) { log("spec/slow_spec.rb": 9.0, "spec/ok_spec.rb": 1.0) }

    def failures(bodies, count: 50_000, floor: 100)
      described_class.check(logs(*bodies), ceilings:, floor:, counter: -> { count })
    end

    it "fails and names the file when it is over its ceiling in 2 of 3 logs" do
      found = failures([over, under, over])

      expect(found.size).to eq(1)
      expect(found.first).to include("spec/slow_spec.rb", "2 of 3")
    end

    it "passes when the file is over its ceiling in only 1 of 3 logs" do
      expect(failures([over, under, under])).to be_empty
    end

    it "passes on a file exactly at its ceiling" do
      expect(failures([log("spec/slow_spec.rb": 10.0)] * 3)).to be_empty
    end

    it "does not count a log that lacks a ceilinged file, so a partial log cannot pass" do
      partial = log("spec/ok_spec.rb": 1.0)

      expect(failures([partial] * 3)).to include(a_string_matching(/3 recorded logs.*found 0 of 3/))
    end

    it "fails naming both numbers when the dry-run count is under the floor" do
      found = failures([under] * 3, count: 90, floor: 100)

      expect(found.size).to eq(1)
      expect(found.first).to include("90", "100")
    end

    it "passes a dry-run count at the floor" do
      expect(failures([under] * 3, count: 100, floor: 100)).to be_empty
    end

    it "fails when there are no logs at all" do
      expect(failures([])).to include(a_string_matching(/3 recorded logs/))
    end

    it "fails when the logs hold no entries, whatever the dry run says" do
      expect(failures(["", "Run options: exclude {}\n", ""])).to include(a_string_matching(/3 recorded logs/))
    end

    it "fails when fewer than 3 logs are recorded" do
      expect(failures([under, under])).to include(a_string_matching(/3 recorded logs/))
    end

    it "fails, rather than raising, when the dry run itself fails" do
      counter = -> { raise RuntimeCensus::DryRunFailed, "exit 1" }

      found = described_class.check(logs(under, under, under), ceilings:, floor: 100, counter:)

      expect(found).to include(a_string_matching(/dry run failed: exit 1/))
    end

    it "reports the ceiling failure and the floor failure together" do
      expect(failures([over, over, over], count: 1, floor: 100).size).to eq(2)
    end
  end

  describe "the command line" do
    let(:root) { Dir.mktmpdir("runtime-census-spec") }
    let(:bin_dir) { File.join(root, "bin") }
    let(:script) { File.join(bin_dir, "runtime-census") }

    before do
      FileUtils.mkdir_p(bin_dir)
      FileUtils.cp(File.expand_path("../../bin/runtime-census", __dir__), script)
    end

    after { FileUtils.remove_entry(root) }

    def run_census(*args, path: ENV.fetch("PATH"))
      Open3.capture3({ "PATH" => path }, RbConfig.ruby, script, *args)
    end

    def write_source(body)
      FileUtils.mkdir_p(File.join(root, "tmp"))
      File.write(File.join(root, "tmp", "parallel_runtime_rspec.log"), body)
    end

    def recorded = Dir[File.join(root, "tmp", "runtime-census", "*.log")]

    def record(body)
      write_source(body)
      run_census("--record")
    end

    # A stand-in `bundle` that prints a count and notes the LAIN_SLOW it was given.
    def fake_bundle(output:, status: 0)
      dir = File.join(root, "fakebin")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "bundle"), <<~SH)
        #!/bin/sh
        echo "$LAIN_SLOW" > "#{root}/slow_seen"
        echo "#{output}"
        exit #{status}
      SH
      FileUtils.chmod(0o755, File.join(dir, "bundle"))
      "#{dir}:#{ENV.fetch("PATH")}"
    end

    def record_three(*bodies) = bodies.each { |body| record(body) }

    it "records the pspec log and keeps only the newest 3" do
      write_source(full_log)

      4.times { expect(run_census("--record")[2]).to be_success }

      expect(recorded.size).to eq(3)
    end

    it "refuses an empty or prose-only source log and keeps the good records" do
      record(full_log)

      _out, err, status = record("Run options: exclude {}\n")

      expect(status.exitstatus).to eq(1)
      expect(err).to include("no path:seconds")
      expect(recorded.size).to eq(1)
    end

    it "refuses a partial log that lacks a ceilinged file and keeps the good records" do
      record(full_log)

      _out, err, status = record(log("spec/a_spec.rb": 0.1))

      expect(status.exitstatus).to eq(1)
      expect(err).to include("lacks")
      expect(recorded.size).to eq(1)
    end

    it "prints the slowest files, the sum and the simulated walls from the newest log" do
      record(full_log("spec/big_spec.rb": 8.0))

      out, _err, status = run_census

      expect(status).to be_success
      expect(out).to include("spec/big_spec.rb", "12 workers", "4 workers")
    end

    it "refuses to record when the source log is missing" do
      _out, err, status = run_census("--record")

      expect(status.exitstatus).to eq(1)
      expect(err).to include("parallel_runtime_rspec.log")
    end

    it "exits 2 with usage on an unknown flag" do
      _out, err, status = run_census("--bogus")

      expect(status.exitstatus).to eq(2)
      expect(err).to include("usage")
    end

    describe "--check" do
      let(:over) { full_log("spec/lain/cli/up_spec.rb": 500.0) }
      let(:under) { full_log }

      it "exits 1 naming the file when it is over its ceiling in 2 of 3 recorded logs" do
        record_three(over, under, over)

        out, _err, status = run_census("--check", path: fake_bundle(output: "99999 examples, 0 failures"))

        expect(status.exitstatus).to eq(1)
        expect(out).to include("spec/lain/cli/up_spec.rb")
      end

      it "exits 0 when all is within bounds, and runs the dry run with LAIN_SLOW=1" do
        record_three(under, under, under)

        _out, _err, status = run_census("--check", path: fake_bundle(output: "99999 examples, 0 failures"))

        expect(status).to be_success
        expect(File.read(File.join(root, "slow_seen")).strip).to eq("1")
      end

      it "exits 1 when the dry run exits non-zero even though it printed a high count" do
        record_three(under, under, under)

        out, _err, status = run_census("--check", path: fake_bundle(output: "99999 examples, 0 failures", status: 1))

        expect(status.exitstatus).to eq(1)
        expect(out).to include("dry run failed")
      end

      it "exits 1 with nothing recorded" do
        _out, _err, status = run_census("--check", path: fake_bundle(output: "99999 examples, 0 failures"))

        expect(status.exitstatus).to eq(1)
      end
    end
  end
end
