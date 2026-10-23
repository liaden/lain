# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "json"
require "open3"
require "rbconfig"

load File.expand_path("../bin/suite-profile", __dir__)

# Never runs a lens: a lens is a whole suite. The commands are proven by what they would run.
RSpec.describe SuiteProfile do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:quiet) { -> { 0 } }

  def main(*argv, counter: quiet, path: "/nowhere", root: Dir.mktmpdir)
    described_class.main(argv, out:, err:, counter:, path:, root: Pathname(root), date: "2026-10-22")
  end

  describe "argument handling" do
    it "refuses no lens with the usage and status 2" do
      expect(main).to eq(2)
      expect(err.string).to include("usage: bin/suite-profile")
    end

    it "refuses an unknown lens, naming the real ones" do
      expect(main("flame")).to eq(2)
      expect(err.string).to include("unknown lens flame", *described_class::LENSES.keys)
    end
  end

  describe "the busy refusal" do
    it "refuses while a suite or hook runs, and starts nothing" do
      root = Dir.mktmpdir

      expect(main("dissect", counter: -> { 2 }, root:)).to eq(1)
      expect(err.string).to include("busy")
      expect(Dir.children(root)).to be_empty
    end

    it "refuses even a dry run, since the box state is part of the answer" do
      expect(main("gc", "--dry-run", counter: -> { 1 })).to eq(1)
    end

    it "counts the same processes the CLAUDE.md quiet check names" do
      quoted = File.read(File.expand_path("../CLAUDE.md", __dir__)).scan(/pgrep -cf '([^']+)'/).flatten

      expect(quoted).not_to be_empty
      expect(described_class::BUSY_PATTERNS).to include(*quoted)
    end
  end

  describe "the missing rbspy message" do
    it "names cargo install rbspy and exits 1" do
      Dir.mktmpdir do |empty|
        expect(main("rbspy", path: empty)).to eq(1)
        expect(err.string).to include("cargo install rbspy")
      end
    end

    it "is found on PATH" do
      Dir.mktmpdir do |bin|
        File.write(File.join(bin, "rbspy"), "")
        File.chmod(0o755, File.join(bin, "rbspy"))

        expect(main("rbspy", "--dry-run", path: bin)).to eq(0)
      end
    end

    it "does not ask for rbspy on the other lenses" do
      expect(main("dissect", "--dry-run", path: "/nowhere")).to eq(0)
    end
  end

  describe "the commands a lens would run (--dry-run)" do
    def dry(lens, root: Dir.mktmpdir)
      Dir.mktmpdir do |bin|
        File.write(File.join(bin, "rbspy"), "")
        File.chmod(0o755, File.join(bin, "rbspy"))
        main(lens, "--dry-run", path: bin, root:)
      end
      out.string
    end

    it "writes to tmp/suite-profile/<date>-<lens> and never to the packer's runtime log" do
      root = Dir.mktmpdir
      text = dry("dissect", root:)

      expect(text).to include("#{root}/tmp/suite-profile/2026-10-22-dissect")
      expect(text).to include("--out #{root}/tmp/suite-profile/2026-10-22-dissect/runtime.log")
      expect(text).to include("--runtime-log tmp/parallel_runtime_rspec.log")
    end

    it "creates nothing" do
      root = Dir.mktmpdir
      dry("gc", root:)

      expect(Dir.children(root)).to be_empty
    end

    it "runs the slow files, packed by the real runtime log" do
      expect(dry("gc")).to include("LAIN_SLOW=1", "parallel_rspec spec", "--group-by runtime")
    end

    it "sets RSpecDissect and TagProf for dissect" do
      expect(dry("dissect")).to include("RD_PROF=1", "RD_PROF_TOP=25", "TAG_PROF=seam")
    end

    it "sets the stackprof mode for each stack lens" do
      expect(dry("stack-cpu")).to include("TEST_STACK_PROF=1", "TEST_STACK_PROF_MODE=cpu")
      out.truncate(0)
      out.rewind
      expect(dry("stack-wall")).to include("TEST_STACK_PROF_MODE=wall")
    end

    it "gives each worker its own dump through the suffix preload" do
      expect(dry("stack-cpu")).to match(%r{RUBYOPT=-r\S*spec/support/suite_profile/worker_suffix\.rb})
    end

    it "requires the GC hook for gc and the spawn hook for spawns" do
      expect(dry("gc")).to match(%r{--require \S*suite_profile/gc_per_file\.rb})
      out.truncate(0)
      out.rewind
      expect(dry("spawns")).to match(%r{--require \S*suite_profile/spawn_tally\.rb})
    end

    it "wraps the suite in rbspy record with subprocesses for rbspy" do
      expect(dry("rbspy")).to match(/rbspy record --subprocesses --nonblocking --rate 50 .* -- /)
    end
  end

  describe "an existing output directory" do
    it "is never overwritten" do
      root = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(root, "tmp/suite-profile/2026-10-22-gc"))

      expect(main("gc", counter: quiet, root:)).to eq(1)
      expect(err.string).to include("already exists")
    end
  end

  describe SuiteProfile::Summary::Dissect do
    let(:log) do
      <<~LOG
        Total time: 01:00.0
        Total setup time: 00:06.0
        Total time: 00:30.0
        Total setup time: 00:03.0
        \e[1mFoo group\e[0m (./spec/a_spec.rb:3) – 00:04.5 of 00:30.0 / 12
        Bar group (./spec/b_spec.rb:9) – 00:01.5 of 00:10.0 / 3
      LOG
    end

    it "sums the workers and ranks the groups by setup time" do
      lines = described_class.call(log).lines.map(&:strip)

      expect(lines.first).to eq("workers 2  total 90.0s  setup 9.0s (10.0%)")
      expect(lines[1]).to match(%r{4\.50s setup of\s+30\.00s\s+12 ex\s+\./spec/a_spec\.rb\s+Foo group})
      expect(lines[2]).to include("Bar group")
    end
  end

  describe SuiteProfile::Summary::Gc do
    it "totals GC time per file and names the suite end" do
      Dir.mktmpdir do |dir|
        rows = [{ file: "./a_spec.rb", wall: 2.0, time: 500, total_allocated_objects: 1_000_000,
                  minor_gc_count: 3, major_gc_count: 1 },
                { file: "./a_spec.rb", wall: 1.0, time: 250, total_allocated_objects: 1_000_000,
                  minor_gc_count: 1, major_gc_count: 0 },
                { file: "./b_spec.rb", wall: 1.0, time: 50, total_allocated_objects: 0,
                  minor_gc_count: 0, major_gc_count: 0 },
                { suite_end: { time: 900 } }]
        File.write(File.join(dir, "w1x1.ndjson"), rows.map(&:to_json).join("\n"))

        lines = described_class.call(dir).lines.map(&:strip)

        expect(lines[0]).to eq("in examples: gc 0.8s of 4.0s example wall (20.0%), 2M objects, 1 major")
        expect(lines[1]).to eq("whole worker lifetimes: gc 0.9s")
        expect(lines[3]).to match(%r{0\.75s gc\s+3\.0s wall\s+2\.0M obj\s+1 major\s+\./a_spec\.rb})
      end
    end
  end

  describe SuiteProfile::Summary::Spawns do
    it "merges the workers' tallies and ranks call sites" do
      Dir.mktmpdir do |dir|
        one = [{ shape: "status", site: "x.rb:1", n: 2 }, { shape: "log", site: "y.rb:2", n: 1 }]
        two = [{ shape: "status", site: "x.rb:1", n: 3 }]
        File.write(File.join(dir, "w1x1.ndjson"), one.map(&:to_json).join("\n"))
        File.write(File.join(dir, "w2x2.ndjson"), two.map(&:to_json).join("\n"))

        lines = described_class.call(dir).lines.map(&:strip)

        expect(lines[0]).to eq("== 6 git spawns")
        expect(lines[1]).to match(/\A5\s+status\s+x\.rb:1\z/)
        expect(lines[2]).to match(/\A1\s+log\s+y\.rb:2\z/)
      end
    end
  end

  describe SuiteProfile::Summary::Rbspy do
    it "splits thread-seconds by process kind and state, and names the sleepers" do
      collapsed = <<~COLLAPSED
        main - /r/bin/rspec:1;run - /x/rspec-core-3/runner.rb:5;block - /dev/lain/spec/foo_spec.rb:9;Kernel#sleep [c function] - (unknown) 100
        main - /r/bin/rspec:1;run - /x/rspec-core-3/runner.rb:5;work - /dev/lain/lib/lain/a.rb:2;String#scan [c function] - (unknown) 50
        main - /dev/lain/exe/lain:1;Kernel#require [c function] - (unknown);load - /dev/lain/lib/lain.rb:123 150
      COLLAPSED

      lines = described_class.call(collapsed, root: "/dev/lain").lines.map(&:strip)

      expect(lines[0]).to eq("300 samples = 6 thread-seconds")
      expect(lines).to include(match(/rspec_worker\s+waiting\s+2\.0 s/), match(/rspec_worker\s+cpu\s+1\.0 s/),
                               match(/lain_child\s+booting\s+3\.0 s/))
      expect(lines).to include(match(%r{2\.0 s\s+rspec_worker\s+spec/foo_spec\.rb:9}))
    end
  end

  describe "the stack report command" do
    it "merges every worker's dump through stackprof" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "dumps"))
        %w[a b].each { |n| File.write(File.join(dir, "dumps", "#{n}.dump"), "") }

        argv = described_class.stack_report_command(Pathname(dir))

        expect(argv.first(3)).to eq(%w[bundle exec stackprof])
        expect(argv).to include("--text", File.join(dir, "dumps", "a.dump"), File.join(dir, "dumps", "b.dump"))
      end
    end
  end

  describe ".example_count" do
    it "reads the total parallel_tests prints last, not a worker's count" do
      log = "3 examples, 0 failures\n5 examples, 1 failure\n\n8 examples, 1 failure\n"

      expect(described_class.example_count(log)).to eq("8 examples, 1 failure")
    end

    it "says so when the log has no count" do
      expect(described_class.example_count("boom")).to eq("no example count")
    end
  end

  describe "the hooks under spec/support/suite_profile" do
    hooks = %w[worker_suffix gc_per_file spawn_tally]
    dir = File.expand_path("support/suite_profile", __dir__)
    probe = <<~RUBY
      module RSpec
        def self.configure = abort("RSpec.configure ran")
      end
      require "fileutils"
      require "json"
      before = Process.singleton_class.ancestors.dup
      ARGV.each { |hook| load hook }
      abort("prepended") unless Process.singleton_class.ancestors == before
      abort("TEST_PROF_REPORT set") if ENV.key?("TEST_PROF_REPORT")
    RUBY

    def run_probe(code, hook_paths, env)
      Dir.mktmpdir do |cwd|
        out, status = Open3.capture2e(env, RbConfig.ruby, "-e", code, *hook_paths, chdir: cwd, unsetenv_others: false)
        [out, status.success?, Dir.children(cwd)]
      end
    end

    let(:unset) do
      { "SUITE_PROFILE_DIR" => nil, "SUITE_PROFILE_LENS" => nil, "TEST_ENV_NUMBER" => "3", "TEST_PROF_REPORT" => nil }
    end

    it "print nothing, write nothing, prepend nothing and configure nothing with the env unset" do
      paths = hooks.map { |hook| File.join(dir, "#{hook}.rb") }

      expect(run_probe(probe, paths, unset)).to eq(["", true, []])
    end

    it "gate worker_suffix on SUITE_PROFILE_DIR and the worker number together" do
      code = 'load ARGV.first; print ENV.fetch("TEST_PROF_REPORT", "none")'
      path = File.join(dir, "worker_suffix.rb")
      with_dir = unset.merge("SUITE_PROFILE_DIR" => "/x")

      expect(run_probe(code, [path], with_dir).first).to match(/\Aw3x\d+\z/)
      expect(run_probe(code, [path], with_dir.merge("TEST_ENV_NUMBER" => nil)).first).to eq("none")
      expect(run_probe(code, [path], unset).first).to eq("none")
    end
  end
end
