# frozen_string_literal: true

# The in-process arm of the exec seam: what Tools::Bash used to do inline, named
# and shared. Two responsibilities are asserted here and nowhere else -- which
# runner a command shape reaches (a String is a shell's problem, a term is not),
# and what environment a child of this process is handed.
RSpec.describe Lain::Exec::Local do
  subject(:backend) { described_class.new }

  def run(command, env: ENV.to_h, cwd: Dir.pwd, timeout: 10)
    backend.call(command:, cwd:, env:, timeout:)
  end

  describe "the two arms it runs" do
    it "runs a String through the shell and captures exit status, stdout and stderr" do
      capture = run(%(sh -c 'echo out; echo err 1>&2; exit 3'))

      expect(capture.exit_status).to eq(3)
      expect(capture.stdout).to include("out")
      expect(capture.stderr).to include("err")
    end

    it "runs a TERM as argv, with no shell process at all" do
      no_shell = described_class.new(shell_out_factory: ->(*, **) { raise "a shell was spawned" })

      capture = no_shell.call(command: [%w[printf hi]], cwd: Dir.pwd, env: ENV.to_h, timeout: 10)

      expect(capture.exit_status).to eq(0)
      expect(capture.stdout).to eq("hi")
    end
  end

  # lain runs under `bundle exec`, so BUNDLE_GEMFILE and friends name LAIN's
  # own toolchain; a child inheriting them resolves lain's Gemfile instead of the
  # project it was pointed at. Grader::TestHarness already knew this; the tool the
  # model actually uses did not.
  describe "lain's own toolchain does not reach the child" do
    it "scrubs BUNDLE_GEMFILE, so a child does not resolve lain's own Gemfile" do
      with_env("BUNDLE_GEMFILE" => "/home/tara/dev/lain/Gemfile") do
        expect(run(%(sh -c 'echo "[$BUNDLE_GEMFILE]"')).stdout).to include("[]")
      end
    end

    it "scrubs the whole framework family, not one variable" do
      family = { "BUNDLE_GEMFILE" => "/lain/Gemfile", "BUNDLER_SETUP" => "/lain/setup.rb",
                 "RUBYOPT" => "-rbundler/setup", "RSPEC_OPTS" => "--seed 1" }

      with_env(family) do
        capture = run(%(sh -c 'env | grep -E "^(BUNDLE_|BUNDLER_|RSPEC_|RUBYOPT=)"; echo scanned'))

        expect(capture.stdout).to eq("scanned\n")
      end
    end

    it "scrubs on the TERM arm too, so the arm a command took cannot change its environment" do
      with_env("BUNDLE_GEMFILE" => "/lain/Gemfile") do
        capture = backend.call(command: [%w[printenv BUNDLE_GEMFILE]],
                               cwd: Dir.pwd, env: ENV.to_h, timeout: 10)

        expect(capture.stdout).to eq("")
        expect(capture.exit_status).not_to eq(0)
      end
    end

    it "keeps GEM_HOME, because the child still has to find its gems" do
      with_env("GEM_HOME" => "/tmp/lain-t1-gems") do
        expect(run(%(sh -c 'echo "[$GEM_HOME]"')).stdout).to include("[/tmp/lain-t1-gems]")
      end
    end

    it "delivers a variable the caller deliberately lent" do
      capture = run(%(sh -c 'echo "[$LAIN_LENT]"'), env: ENV.to_h.merge("LAIN_LENT" => "on loan"))

      expect(capture.stdout).to include("[on loan]")
    end

    # WorkerEnv's posture is unchanged for everything else: the env map is an
    # additive override, not confinement, and only the framework family is taken
    # away from the child.
    it "still leaks a non-framework host var the caller's env omits" do
      with_env("LAIN_HOST_ONLY" => "leaked") do
        capture = run(%(sh -c 'echo "[$LAIN_HOST_ONLY]"'), env: { "PATH" => ENV.fetch("PATH") })

        expect(capture.stdout).to include("[leaked]")
      end
    end
  end

  # Whether a backend can take a term is a question about THE TERM, not about
  # the backend: Exec::Docker answers differently for a one-stage term and a
  # piped one. This backend runs both through the same pipeline, so its answer
  # is the same for every term -- and a caller holding one asks before it
  # offers. Declared below as this backend's row of the seam's truth table; the
  # CONTRACT that row is checked against is one shared file, so the seam's third
  # required message cannot stay a promise only a comment makes.
  describe "the terms it says it can take" do
    def run_term(term) = run(term)
    def terms_taken = [[%w[printf hi]], [%w[printf hi], %w[cat]]]
    def terms_refused = []

    it_behaves_like "an exec backend answering for a term"
  end

  describe "a deadline that passes" do
    it "raises Exec::Timeout when a String command outlives its timeout" do
      # The injected factory only shortens mixlib's hardcoded TERM->KILL grace.
      short_grace = lambda do |*args, **opts|
        Mixlib::ShellOut.new(*args, **opts).tap do |shell_out|
          def shell_out.sleep(_grace) = super(0.1)
        end
      end

      expect do
        described_class.new(shell_out_factory: short_grace)
                       .call(command: %(sh -c 'sleep 5'), cwd: Dir.pwd, env: ENV.to_h, timeout: 1)
      end.to raise_error(Lain::Exec::Timeout, /timed out/i)
    end

    # mixlib builds its timeout message by interpolating the command beside a
    # BINARY capture, which raises on a non-ASCII command once the capture holds
    # a high byte -- and an encoding error is not a timeout to any caller.
    it "raises Exec::Timeout, not an encoding error, for a non-ASCII command that printed non-ASCII" do
      short_grace = lambda do |*args, **opts|
        Mixlib::ShellOut.new(*args, **opts).tap do |shell_out|
          def shell_out.sleep(_grace) = super(0.1)
        end
      end

      expect do
        described_class.new(shell_out_factory: short_grace)
                       .call(command: %(sh -c "printf '\\342\\234\\205'; : ✅; sleep 5"), cwd: Dir.pwd,
                             env: ENV.to_h, timeout: 1)
      end.to raise_error(Lain::Exec::Timeout) { |error| expect(error.message.b).to include("✅".b) }
    end

    it "hands the shell the command's own bytes" do
      capture = run(%(sh -c "printf '%s' '✅ café'"))

      expect(capture.stdout.b).to eq("✅ café".b)
    end

    it "raises the SAME Exec::Timeout when a term outlives its timeout" do
      slow_grace = described_class.new(pipeline: Lain::Shell::Pipeline.new(grace: 0.1))

      expect do
        slow_grace.call(command: [%w[sleep 5]], cwd: Dir.pwd, env: ENV.to_h, timeout: 1)
      end.to raise_error(Lain::Exec::Timeout)
    end
  end
end
