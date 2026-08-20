# frozen_string_literal: true

require "mixlib/shellout"

# Drives real subprocesses, because every property here IS a property of the
# spawn: what the child inherits, what it does not, and what happens when it
# refuses to die. A double would be asserting this file's own beliefs about
# `Process.spawn`, which is the thing under test.
#
# `Mixlib::ShellOut` appears as an ORACLE, not as a collaborator. The subject
# exists to be substitutable for it under {Isolation::Worktree}, so the claim
# worth pinning is agreement, not behaviour in isolation -- a subject that
# quietly disagreed about (say) a nil environment value would pass every
# hand-written expectation and still break the caller it was written for.
RSpec.describe Lain::Shell::Out do
  def both(*argv, **)
    [described_class.new(*argv, **).run_command, Mixlib::ShellOut.new(*argv, **).run_command]
  end

  describe "the three values a caller reads back" do
    it "captures stdout, stderr and the exit status of a real command" do
      shell = described_class.new("sh", "-c", "printf out; printf err >&2; exit 3").run_command

      expect(shell.stdout).to eq("out")
      expect(shell.stderr).to eq("err")
      expect(shell.exitstatus).to eq(3)
    end

    it "reports a nonzero exit rather than raising, as the seam's callers require" do
      expect { described_class.new("false").run_command }.not_to raise_error
      expect(described_class.new("false").run_command.exitstatus).to eq(1)
    end

    it "answers itself, so `run_command.stdout` reads as it does with mixlib" do
      shell = described_class.new("true")

      expect(shell.run_command).to be(shell)
    end

    it "agrees with Mixlib::ShellOut on all three" do
      mine, theirs = both("sh", "-c", "printf hello; printf oops >&2; exit 7")

      expect([mine.stdout, mine.stderr, mine.exitstatus])
        .to eq([theirs.stdout, theirs.stderr, theirs.exitstatus])
    end

    # A payload past one CHUNK is where a naive read-then-wait deadlocks: the
    # child blocks writing into a full pipe while the parent blocks on waitpid.
    it "captures output larger than one read, on both streams at once" do
      size = (Lain::Shell::Out::CHUNK * 3) + 17
      shell = described_class.new("sh", "-c", "yes x | head -c #{size}; yes y | head -c #{size} >&2").run_command

      expect(shell.stdout.bytesize).to eq(size)
      expect(shell.stderr.bytesize).to eq(size)
    end

    it "keeps binary output byte-identical to what mixlib captures" do
      mine, theirs = both("printf", '\376\377\000\001')

      expect(mine.stdout.bytes).to eq(theirs.stdout.bytes)
    end
  end

  describe "the environment the child gets" do
    it "adds a variable to the parent's environment rather than replacing it" do
      shell = described_class.new("sh", "-c", 'printf "$LAIN_OUT_SPEC/$PATH"',
                                  environment: { "LAIN_OUT_SPEC" => "set" }).run_command

      expect(shell.stdout).to eq("set/#{ENV.fetch("PATH")}")
    end

    # The semantics GIT_CONTEXT_SCRUB is built on: a nil value DELETES.
    it "deletes an inherited variable mapped to nil, as mixlib does" do
      with_env("LAIN_OUT_SPEC" => "inherited") do
        mine, theirs = both("sh", "-c", 'printf "[$LAIN_OUT_SPEC]"', environment: { "LAIN_OUT_SPEC" => nil })

        expect(mine.stdout).to eq("[]")
        expect(theirs.stdout).to eq("[]")
      end
    end

    it "scrubs the git context the isolation callers hand it" do
      with_env("GIT_DIR" => "/nowhere/.git") do
        shell = described_class.new("sh", "-c", 'printf "[$GIT_DIR]"',
                                    environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command

        expect(shell.stdout).to eq("[]")
      end
    end
  end

  describe "no shell ever sees the command" do
    it "runs a one-word command as a program, not as a line to re-split" do
      shell = described_class.new("echo").run_command

      expect(shell.exitstatus).to eq(0)
      expect(shell.stdout).to eq("\n")
    end

    # The wrong neighbour: `Process.spawn(String)` shells out on a metacharacter,
    # so this would have written the file.
    it "looks for a program named with the metacharacters rather than obeying them" do
      Dir.mktmpdir("lain-out") do |dir|
        target = File.join(dir, "pwned")

        expect { described_class.new("echo hi > #{target}").run_command }.to raise_error(Errno::ENOENT)
        expect(File.exist?(target)).to be(false)
      end
    end

    it "does not re-split a one-word command holding a space" do
      expect { described_class.new("no such program").run_command }.to raise_error(Errno::ENOENT)
    end

    it "raises Errno::ENOENT for a program that is not there, as mixlib does" do
      expect { described_class.new("lain-no-such-binary", "--version").run_command }
        .to raise_error(Errno::ENOENT)
      expect { Mixlib::ShellOut.new("lain-no-such-binary", "--version").run_command }
        .to raise_error(Errno::ENOENT)
    end
  end

  describe "stdin" do
    # Inheriting lain's stdin would have the child read the human's keystrokes.
    it "hands the child no input, so a reader sees EOF instead of the terminal" do
      shell = described_class.new("cat").run_command

      expect(shell.stdout).to eq("")
      expect(shell.exitstatus).to eq(0)
    end
  end

  describe "a child that outlives its bound" do
    it "raises Timeout rather than waiting" do
      expect { described_class.new("sleep", "30", timeout: 0.2).run_command }
        .to raise_error(described_class::Timeout, /timed out after 0.2s: sleep 30/)
    end

    # The point of `pgroup: true`: a shell that has forked its own child is the
    # normal case, and killing only the shell leaves the sleep running.
    it "kills the command's own descendants, not only the command" do
      Dir.mktmpdir("lain-out") do |dir|
        marker = File.join(dir, "pid")
        script = "sh -c 'echo $$ > #{marker}; sleep 30' & wait"

        expect { described_class.new("sh", "-c", script, timeout: 0.5).run_command }
          .to raise_error(described_class::Timeout)

        grandchild = File.read(marker).strip.to_i
        expect(grandchild).to be_positive
        wait_until { !alive?(grandchild) }
        expect(alive?(grandchild)).to be(false)
      end
    end

    # A killed child still has to be REAPED. Without it the raise leaves a
    # zombie per timeout, which a long-lived agent accumulates until it cannot
    # fork at all -- and nothing else here would notice.
    #
    # Asked of the pid the SUBJECT spawned, never of `waitpid(-1)`. The global
    # form answers for every child in the process, so it is not this subject's
    # property at all -- it fails whenever anything ELSE in the suite has a reap
    # still outstanding, an Open3 wait thread {Shell::Pipeline} left pending past
    # its join grace being the one that bit. That can only overlap when the whole
    # suite shares one process, which is the CI shape and not the local one
    # (`spec_workers` is `physical_cores - 1`, and the runner has two), so it read
    # green on every dev box and red in CI. ECHILD is the whole assertion: the
    # child is GONE rather than waiting to be collected.
    it "leaves no zombie behind" do
      spawned = nil
      allow(Process).to receive(:spawn).and_wrap_original do |spawn, *argv, **options|
        spawned = spawn.call(*argv, **options)
      end

      expect { described_class.new("sleep", "30", timeout: 0.2).run_command }
        .to raise_error(described_class::Timeout)

      expect(spawned).to be_positive
      expect { Process.waitpid(spawned, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
    end

    # The bound is measured against the injected clock, which is what lets an
    # example assert a 10s timeout without waiting 10s -- and what keeps the
    # monotonic primitive named once in lib/, in {Lain::RunClock::MONOTONIC}.
    it "measures its bound against the clock it was given, not the wall" do
      elapsed = 0.0
      jumping = -> { elapsed += 50.0 }

      expect { described_class.new("sleep", "30", timeout: 10, clock: jumping).run_command }
        .to raise_error(described_class::Timeout, /timed out after 10s/)
    end

    it "runs to completion when the child finishes inside its bound" do
      expect(described_class.new("sleep", "0.01", timeout: 30).run_command.exitstatus).to eq(0)
    end
  end

  describe "a child killed by a signal" do
    it "reports a nil exit status, the same nil mixlib reports" do
      mine, theirs = both("sh", "-c", "kill -TERM $$")

      expect(mine.exitstatus).to be_nil
      expect(theirs.exitstatus).to be_nil
    end
  end

  describe "options it does not implement" do
    it "refuses a mixlib keyword rather than ignoring it" do
      expect { described_class.new("true", cwd: "/tmp") }.to raise_error(ArgumentError)
    end
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end
end
