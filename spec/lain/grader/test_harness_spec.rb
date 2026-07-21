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
          .to raise_error(Lain::Grader::TestHarness::Adapter::Undetectable, /rspec.*jest.*pytest/m)
      end
    end

    it "raises when the framework matches but its adapter is unimplemented" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "pytest.ini"), "[pytest]\n")

        expect { described_class.new(dir) }
          .to raise_error(Lain::Grader::TestHarness::Adapter::Undetectable, /pytest/)
      end
    end

    it "raises on ambiguity rather than guessing" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile"), "")
        Dir.mkdir(File.join(dir, "spec"))
        File.write(File.join(dir, "pytest.ini"), "")

        expect { described_class.new(dir) }
          .to raise_error(Lain::Grader::TestHarness::Adapter::Undetectable, /rspec.*pytest|pytest.*rspec/)
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
