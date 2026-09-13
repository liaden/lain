# frozen_string_literal: true

# Grader::TestHarness runs a project's OWN test suite as a fixture and folds the
# pass/fail counts into a Grade. Two invariants matter: the machine-readable
# result is written to a FILE so the child project's stdout noise never corrupts
# the parse, and the child runs with the host's bundler/rspec context scrubbed so
# it resolves its own project, not lain's. The adapter is a duck (rspec first,
# a runtime-free Command adapter proving the seam); detection is loud.
RSpec.describe Lain::Grader::TestHarness do
  # The real rspec_mini fixture: 2 passing, 1 failing, printing deprecation noise.
  let(:rspec_mini) { File.expand_path("../../fixtures/projects/rspec_mini", __dir__) }

  # A WorkerEnv-shaped value (cwd + env). TestHarness duck-types on #cwd/#env, so
  # the real Lain::WorkerEnv is used when this worktree carries it and a faithful
  # two-field stand-in otherwise (this card's worktree forked before WorkerEnv
  # landed -- see the handback).
  worker_env_class = defined?(Lain::WorkerEnv) ? Lain::WorkerEnv : Data.define(:cwd, :env)

  def worker_env_for(dir, klass)
    klass.new(cwd: dir, env: ENV.to_h)
  end

  describe "grading a real rspec project" do
    subject(:harness) { described_class.new(rspec_mini) }

    it "scores 2/3, does not pass, and names the failing example" do
      grade = harness.grade(worker_env_for(rspec_mini, worker_env_class))

      expect(grade.score).to eq(2.0 / 3)
      expect(grade).not_to be_pass
      expect(grade.why).to include("divides evenly (intentionally failing)")
    end

    it "grades identically despite the project's stdout deprecation noise" do
      first = harness.grade(worker_env_for(rspec_mini, worker_env_class))
      second = harness.grade(worker_env_for(rspec_mini, worker_env_class))

      # Byte-for-byte identical Grades across runs -- the stdout noise the fixture
      # emits reaches neither the JSON result nor this process.
      expect(first).to eq(second)
      expect(first.score).to eq(2.0 / 3)
    end

    it "runs the child with the host bundler context scrubbed" do
      captured = nil
      factory = lambda do |*argv, **options|
        captured = options
        Mixlib::ShellOut.new(*argv, **options)
      end
      described_class.new(rspec_mini, shell_out_factory: factory)
                     .grade(worker_env_for(rspec_mini, worker_env_class))

      # Every inherited BUNDLE_*/BUNDLER_*/RSPEC_* var and RUBYOPT is mapped to
      # nil (the WorkerEnv scrub semantics -- a nil value deletes the key in the
      # child), so the host Gemfile can never leak in.
      scrubbed = captured.fetch(:environment)
      expect(scrubbed).to include("BUNDLE_GEMFILE" => nil)
      expect(scrubbed["RUBYOPT"]).to be_nil
    end
  end

  describe "detection is loud, injection wins" do
    it "raises a named error listing every probe when nothing matches" do
      Dir.mktmpdir do |empty|
        expect { described_class.new(empty) }
          .to raise_error(Lain::Error, /rspec.*jest.*pytest/m)
      end
    end

    it "raises when the framework matches but its adapter is unimplemented" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "pytest.ini"), "[pytest]\n")

        expect { described_class.new(dir) }
          .to raise_error(Lain::Error, /detected pytest in .* adapter is not implemented/)
      end
    end

    it "raises on ambiguity rather than guessing" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile"), "")
        Dir.mkdir(File.join(dir, "spec"))
        File.write(File.join(dir, "pytest.ini"), "")

        expect { described_class.new(dir) }
          .to raise_error(Lain::Error, /rspec.*pytest|pytest.*rspec/)
      end
    end

    it "an explicit Command adapter grades the same directory that detection rejects" do
      command = Lain::Grader::TestHarness::Adapter::Command.new(
        out_argv: ->(out_path) { ["sh", "-c", "printf 'PASS a\\nPASS b\\nFAIL c\\n' > #{out_path}"] },
        passed: /\APASS (.+)/,
        failed: /\AFAIL (.+)/
      )

      Dir.mktmpdir do |empty|
        harness = described_class.new(empty, adapter: command)
        grade = harness.grade(worker_env_for(empty, worker_env_class))

        expect(grade.score).to eq(2.0 / 3)
        expect(grade).not_to be_pass
        expect(grade.why).to include("c")
      end
    end
  end

  # A level root narrows the run: grading a unit-level criterion runs the unit
  # root, not the whole suite. The fixture's test files are written into a
  # copy because a committed *_spec.rb would be collected by lain's own suite.
  describe "a level root narrows the test run", :seam do
    let(:layout_mini) { File.expand_path("../../fixtures/projects/layout_mini", __dir__) }
    let(:rspec) { Lain::Grader::TestHarness::Adapter::Rspec.new }

    def with_levels
      Dir.mktmpdir do |root|
        FileUtils.cp_r(File.join(layout_mini, "."), root)
        write_spec(root, "spec/unit/models/order_spec.rb", "unit order", "totals", "refunds")
        write_spec(root, "spec/seam/models/order_spec.rb", "seam order", "persists")
        yield root
      end
    end

    def write_spec(root, relative, group, *examples)
      path = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "RSpec.describe #{group.inspect} do\n" \
                       "#{examples.map { |example| "  it(#{example.inspect}) { expect(1).to eq(1) }\n" }.join}end\n")
    end

    it "counts only spec/unit examples when run with paths [\"spec/unit\"]" do
      with_levels do |root|
        harness = described_class.new(root, adapter: rspec)
        run = harness.run(worker_env_for(root, worker_env_class), paths: ["spec/unit"])

        expect(run.passed).to contain_exactly("unit order totals", "unit order refunds")
      end
    end

    it "grades the same narrowed run, and the whole suite with no paths" do
      with_levels do |root|
        harness = described_class.new(root, adapter: rspec)
        env = worker_env_for(root, worker_env_class)

        expect([harness.grade(env, paths: ["spec/seam"]).why, harness.grade(env).why])
          .to eq(["all 1 examples passed", "all 3 examples passed"])
      end
    end

    it "hands the paths to the adapter's command after its own arguments" do
      command = Lain::Grader::TestHarness::Adapter::Command.new(out_argv: ->(out) { ["runner", out] },
                                                                passed: /x/, failed: /y/)

      expect([rspec.command(out_path: "/r", paths: ["spec/unit"]), command.command(out_path: "/r", paths: ["t"])])
        .to eq([%w[rspec --format json --out /r spec/unit], %w[runner /r t]])
    end
  end

  # A level root that does not exist yet -- a project with unit tests and no
  # seam root -- would otherwise reach rspec as a file to load, and grade its
  # LoadError as a failing suite.
  describe "a path that is not there" do
    it "raises MissingPaths naming it, before anything is spawned" do
      spawned = []
      factory = ->(*argv, **) { spawned << argv }

      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "spec/unit"))
        harness = described_class.new(root, adapter: Lain::Grader::TestHarness::Adapter::Rspec.new,
                                            shell_out_factory: factory)

        expect { harness.run(worker_env_for(root, worker_env_class), paths: ["spec/unit", "spec/seam"]) }
          .to raise_error(described_class::MissingPaths, %r{spec/seam(?!.*spec/unit)})
        expect(spawned).to be_empty
      end
    end
  end

  # The framework's NAME, for a caller building a test layout: it detects
  # without building an adapter, so a framework lain cannot run yet still
  # names its layout's preset.
  describe "Adapter.framework" do
    it "names the single framework a root matches, and nil for none or several" do
      Dir.mktmpdir do |dir|
        none = Lain::Grader::TestHarness::Adapter.framework(dir)
        File.write(File.join(dir, "pytest.ini"), "")
        single = Lain::Grader::TestHarness::Adapter.framework(dir)
        File.write(File.join(dir, "Gemfile"), "")
        Dir.mkdir(File.join(dir, "spec"))

        expect([none, single, Lain::Grader::TestHarness::Adapter.framework(dir)]).to eq([nil, "pytest", nil])
      end
    end
  end

  describe "a hung child is bounded by an injectable timeout" do
    it "raises a named Timeout (not the raw mixlib class) naming the command and the limit" do
      sleeper = Lain::Grader::TestHarness::Adapter::Command.new(
        out_argv: ->(out_path) { ["sh", "-c", "sleep 5 > #{out_path}"] },
        passed: /\APASS (.+)/, failed: /\AFAIL (.+)/
      )

      Dir.mktmpdir do |dir|
        harness = described_class.new(dir, adapter: sleeper, timeout: 0.3)

        expect { harness.grade(worker_env_for(dir, worker_env_class)) }
          .to raise_error(Lain::Grader::TestHarness::Timeout, /sleep 5.*0\.3/m)
      end
    end
  end

  describe "a load crash surfaces the real error in why" do
    # The broken project is built in a tempdir, not committed as a fixture: a
    # syntax-broken *.rb file in the repo would fail rubocop's own parse.
    it "names the SyntaxError from a spec file that fails to load" do
      Dir.mktmpdir do |dir|
        Dir.mkdir(File.join(dir, "spec"))
        File.write(File.join(dir, "Gemfile"), "")
        File.write(File.join(dir, ".rspec"), "--pattern spec/**/*_check.rb\n")
        File.write(File.join(dir, "spec", "broken_check.rb"), "def oops( this is not valid ruby\n")

        grade = described_class.new(dir).grade(worker_env_for(dir, worker_env_class))

        expect(grade).not_to be_pass
        expect(grade.score).to eq(0.0)
        expect(grade.why).to include("SyntaxError")
      end
    end
  end
end
