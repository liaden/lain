# frozen_string_literal: true

require "json"
require "pty"
require "rbconfig"
require "tmpdir"

# The in-process arm of the exec seam: what Tools::Bash used to do inline, named
# and shared. Three responsibilities are asserted here and nowhere else -- which
# shape a command reaches the one runner in (a String is a shell's problem, a
# term is not), how much of what it prints is held, and what environment a child
# of this process is handed.
RSpec.describe Lain::Exec::Local do
  subject(:backend) { described_class.new }

  def run(command, env: ENV.to_h, cwd: Dir.pwd, timeout: 10)
    backend.call(command:, cwd:, env:, timeout:)
  end

  # A runner that records the shape it was handed and runs nothing.
  def recording_pipeline
    seen = []
    pipeline = lambda do |term, capture:, **|
      seen << term
      capture.finish(0)
    end
    [pipeline, seen]
  end

  def flooding(bytes) = "head -c #{bytes} /dev/zero | tr '\\0' a"

  describe "the two arms it runs" do
    it "runs a String through the shell and captures exit status, stdout and stderr" do
      capture = run(%(sh -c 'echo out; echo err 1>&2; exit 3'))

      expect(capture.exit_status).to eq(3)
      expect(capture.stdout).to include("out")
      expect(capture.stderr).to include("err")
    end

    it "runs a TERM as argv, with no shell process at all" do
      pipeline, seen = recording_pipeline

      described_class.new(pipeline:).call(command: [%w[printf hi]], cwd: Dir.pwd, env: ENV.to_h, timeout: 10)

      expect(seen).to eq([[%w[printf hi]]])
    end

    # One runner, so the process group, the kill, the live sinks, the bound and
    # the child's stdin cannot differ by arm. The string is handed to `sh -c`
    # verbatim as one argv word; nothing here ever joins a term into a string.
    it "runs a String as a one-stage `sh -c` term through that same runner" do
      pipeline, seen = recording_pipeline

      described_class.new(pipeline:).call(command: "echo a && echo b", cwd: Dir.pwd, env: ENV.to_h, timeout: 10)

      expect(seen).to eq([[["/bin/sh", "-c", "echo a && echo b"]]])
    end
  end

  describe "a command that leaves a background child behind" do
    def reap(pid)
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    end

    # The command is over when its shell exits, and a child it started in the
    # background is its own business: it is neither waited on nor killed, even
    # while it holds the output pipe open.
    it "returns once the command exits, with what it printed, and leaves the child running" do
      Dir.mktmpdir do |dir|
        pidfile = File.join(dir, "child")
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        child = nil

        capture = run("sleep 30 & echo $! > #{pidfile}; echo started", timeout: 5)

        child = Integer(File.read(pidfile))
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
        expect(capture).to have_attributes(exit_status: 0, stdout: "started\n")
        expect(Process.kill(0, child)).to eq(1)
      ensure
        reap(child) if child
      end
    end
  end

  describe "what it holds of a command's output" do
    subject(:backend) { described_class.new(ceiling: 1024) }

    def held(capture) = capture.stdout.bytesize + capture.stderr.bytesize

    it "holds at most the ceiling plus one byte on the string arm, while counting every byte" do
      capture = run("#{flooding(1_048_576)}; echo done 1>&2")

      expect(capture.size).to eq(1_048_576 + 5)
      expect(held(capture)).to eq(1025)
    end

    it "holds at most the ceiling plus one byte on the term arm, while counting every byte" do
      capture = run([["head", "-c", "1048576", "/dev/zero"], ["tr", "\\0", "a"]])

      expect(capture.size).to eq(1_048_576)
      expect(held(capture)).to eq(1025)
    end

    # Killing the group at the ceiling would replace the command's own status
    # with a signal's, and the status is what a refusal still reports.
    it "keeps draining past the ceiling, so the command's own exit status survives" do
      expect(run("#{flooding(1_048_576)}; exit 3").exit_status).to eq(3)
    end

    # A stage can grow its pipe past one read before it exits, and a busy thread
    # elsewhere in this process can hold the interpreter lock between reads:
    # what it wrote before exiting is still all counted and all forwarded.
    it "takes every byte a stage wrote before exiting, from a grown pipe, while this process is busy" do
      grown = "#{RbConfig.ruby} --disable-gems -e 'STDOUT.fcntl(1031, 1_048_576); STDOUT.write(%(a) * 1_048_576)'"
      sink = RecordingChannel.new
      busy = Thread.new { loop { (1..1000).sum } }

      captures = Array.new(3) do
        backend.call(command: grown, cwd: Dir.pwd, env: ENV.to_h, timeout: 30, stdout_sink: sink)
      end

      expect(captures.map(&:size)).to all(eq(1_048_576))
      expect(sink.events.sum(&:bytesize)).to eq(3 * 1_048_576)
    ensure
      busy&.kill
    end

    it "streams every byte to the live sink, past the ceiling" do
      sink = RecordingChannel.new

      backend.call(command: flooding(1_048_576), cwd: Dir.pwd, env: ENV.to_h, timeout: 10, stdout_sink: sink)

      expect(sink.events.sum(&:bytesize)).to eq(1_048_576)
    end
  end

  # lain runs under `bundle exec`, so BUNDLE_GEMFILE and friends name LAIN's
  # own toolchain; a child inheriting them resolves lain's Gemfile instead of the
  # project it was pointed at. Grader::TestHarness already knew this; the tool the
  # model actually uses did not.
  describe "the shell the string arm runs" do
    it "is /bin/sh by its absolute path, whatever PATH the child is lent" do
      expect(run("echo hi", env: { "PATH" => "/nonexistent/lain/bin" })).to have_attributes(exit_status: 0,
                                                                                            stdout: "hi\n")
    end
  end

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

  # A tool command never shares lain's controlling terminal: one that opens
  # /dev/tty would otherwise write into the chat pane the frontend is painting,
  # and a prompt read from it would stop the command until its deadline. Driven
  # in a CHILD whose controlling terminal is a real pty, because the spec
  # process's own terminal is whatever ran the suite.
  describe "the terminal lain runs on", :seam do
    let(:child) do
      <<~RUBY
        require "json"
        require "lain"

        local = Lain::Exec::Local.new(pipeline: Lain::Shell::Pipeline.new(grace: 0.2))
        prompt = "printf LAIN-TTY-SCRIBBLE > /dev/tty; read answer < /dev/tty"
        arms = { "string" => prompt, "term" => [["sh", "-c", prompt]], "shell-free term" => [["cat", "/dev/tty"]] }
        seen = arms.to_h do |arm, command|
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          outcome = begin
            local.call(command:, cwd: Dir.pwd, env: ENV.to_h, timeout: 2).exit_status
          rescue Lain::Exec::Timeout
            "timed out"
          end
          [arm, { "outcome" => outcome, "seconds" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started }]
        end
        File.write(ARGV.fetch(0), JSON.generate(seen))
      RUBY
    end

    def on_a_pty(dir)
      report = File.join(dir, "seen.json")
      written = +""
      PTY.spawn(RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__), "-e", child, report) do |out, _in, pid|
        loop { written << out.readpartial(4096) }
      rescue EOFError, Errno::EIO
        Process.wait(pid)
      end
      [JSON.parse(File.read(report)), written]
    end

    it "fails a command that opens /dev/tty at once on both arms, and writes nothing to the terminal" do
      Dir.mktmpdir do |dir|
        seen, written = on_a_pty(dir)

        expect(written).not_to include("LAIN-TTY-SCRIBBLE")
        expect(seen.values.map { |arm| arm["outcome"] }).to all(be_an(Integer).and(be_positive)), seen.inspect
        expect(seen.values.map { |arm| arm["seconds"] }).to all(be < 1), seen.inspect
      end
    end
  end

  describe "a deadline that passes" do
    let(:short_grace) { Lain::Shell::Pipeline.new(grace: 0.1) }

    it "raises Exec::Timeout when a String command outlives its timeout" do
      expect do
        described_class.new(pipeline: short_grace)
                       .call(command: %(sh -c 'sleep 5'), cwd: Dir.pwd, env: ENV.to_h, timeout: 1)
      end.to raise_error(Lain::Exec::Timeout)
    end

    it "raises Exec::Timeout, not an encoding error, for a non-ASCII command that printed non-ASCII" do
      expect do
        described_class.new(pipeline: short_grace)
                       .call(command: %(sh -c "printf '\\342\\234\\205'; : ✅; sleep 5"), cwd: Dir.pwd,
                             env: ENV.to_h, timeout: 1)
      end.to raise_error(Lain::Exec::Timeout) { |error| expect(error.message.b).to include("✅".b) }
    end

    # The report is built from the bounded capture, so a command that floods
    # before it hangs cannot put the flood into the message.
    it "quotes at most the ceiling plus one byte of a flood in its report" do
      bounded = described_class.new(pipeline: short_grace, ceiling: 1024)

      expect do
        bounded.call(command: "#{flooding(1_048_576)}; sleep 5", cwd: Dir.pwd, env: ENV.to_h, timeout: 1)
      end.to raise_error(Lain::Exec::Timeout) { |error| expect(error.message.bytesize).to be < 2048 }
    end

    it "hands the shell the command's own bytes" do
      capture = run(%(sh -c "printf '%s' '✅ café'"))

      expect(capture.stdout.b).to eq("✅ café".b)
    end

    it "raises the SAME Exec::Timeout when a term outlives its timeout" do
      expect do
        described_class.new(pipeline: short_grace).call(command: [%w[sleep 5]], cwd: Dir.pwd, env: ENV.to_h, timeout: 1)
      end.to raise_error(Lain::Exec::Timeout)
    end
  end
end
