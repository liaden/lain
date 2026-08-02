# frozen_string_literal: true

require "tmpdir"

# A recording IO-shaped duck: the same surface Sink::Null and Sink::IOAdapter
# present, kept here so a spec can watch bytes arrive as they are produced
# rather than only after the run finishes.
class RecordingSink
  attr_reader :writes

  def initialize
    @writes = []
  end

  def <<(obj)
    @writes << obj.to_s
    self
  end

  def write(*args)
    args.each { |arg| self << arg }
    args.sum { |arg| arg.to_s.bytesize }
  end

  def joined = @writes.join
end

RSpec.describe Lain::Shell::Pipeline do
  subject(:pipeline) { described_class.new(grace: 0.2) }

  def run(term, cwd: Dir.pwd, env: {}, timeout: 10, **sinks)
    pipeline.call(term, cwd:, env:, timeout:, **sinks)
  end

  # THE contract of this object, and the reason it exists: a term is a list of
  # argv arrays, and every one of them reaches `exec` as argv. No stage's bytes
  # are ever re-parsed, re-split, or handed to a shell.
  describe "running a term with no shell anywhere" do
    it "runs a single stage and captures its stdout" do
      result = run([%w[printf hi]])
      expect(result.exit_status).to eq(0)
      expect(result.stdout).to eq("hi")
      expect(result.stderr).to eq("")
    end

    # The positive proof that no shell ran: a shell would have expanded this and
    # printed a home directory. `Open3` execs the word verbatim.
    it "does not expand a dollar sign, because nothing interprets the term" do
      expect(run([["echo", "$HOME"]]).stdout).to eq("$HOME\n")
    end

    # The trap the algebra doc names: `[["grep", "pattern"], ["rspec"]]`, never
    # a `"grep pattern"` string that gets re-split. `Process.spawn` re-splits a
    # lone String argument (and reaches for a shell when it holds metacharacters),
    # so every stage goes through the `[program, argv0]` form, which cannot.
    it "never re-splits a term that happens to contain a space" do
      result = run([["echo hi"]])
      expect(result.exit_status).to eq(127)
      expect(result.stdout).to eq("")
      expect(result.stderr).to include("echo hi")
    end

    it "reports the exit status of a program that fails" do
      expect(run([["false"]]).exit_status).to eq(1)
    end

    it "captures stderr separately from stdout" do
      result = run([["cat", "/nonexistent/lain/probe"]])
      expect(result.stdout).to eq("")
      expect(result.stderr).to include("/nonexistent/lain/probe")
    end

    # `IO#readpartial` hands back ASCII-8BIT and the buffer adopts it on first
    # append -- the same mechanics `Mixlib::ShellOut` accumulates through, which
    # is what keeps the two arms' rendered bytes identical for a binary payload.
    it "carries a non-UTF-8 payload through unmangled" do
      result = run([["printf", '\377\376']])
      expect(result.stdout.b).to eq("\xFF\xFE".b)
    end
  end

  # The card's pipeline scenario, with the term BUILT DIRECTLY. `printf 'a\nb\na\n'
  # | sort | uniq -c` ABSTAINS under Shell::Verdict: Shell::Parse does not strip
  # quotes, so an allowed term would carry literal `'` characters into exec. That
  # narrowing is deliberate and is pinned as its own example below; this example
  # is about Open3 running the stages, not about the verdict.
  describe "a multi-stage term" do
    it "runs the stages in order, piping each into the next" do
      result = run([["printf", "a\nb\na\n"], ["sort"], ["uniq", "-c"]])
      expect(result.exit_status).to eq(0)
      expect(result.stdout.scan(/\d+ \w/)).to eq(["2 a", "1 b"])
    end

    it "abstains at the verdict on the quoted form, so the term path never sees quotes" do
      decision = Lain::Shell::Verdict.new.call("printf 'a\nb\na\n' | sort | uniq -c")
      expect(decision).to be_abstain
      expect(decision.term).to be_empty
    end

    # `sh -c "a | b"` reports the LAST stage's status, because pipefail is off by
    # default. Both arms have to agree on that or the rendered exit status drifts.
    it "reports the last stage's exit status, as an unadorned shell does" do
      result = run([["cat", "/nonexistent/lain/probe"], ["cat"]])
      expect(result.exit_status).to eq(0)
      expect(result.stderr).to include("/nonexistent/lain/probe")
    end
  end

  # The trap from planning/tool-use-algebra.md: pipeline safety is NOT the
  # conjunction of per-stage safety, because a pipe opens a second channel that
  # the model's upstream stage writes into.
  describe "the stronger predicate downstream of a pipe" do
    it "refuses a stage that executes its stdin, and runs nothing" do
      sink = RecordingSink.new
      result = run([%w[echo whoami], ["sh"]], stderr_sink: sink)

      expect(result.exit_status).to eq(126)
      expect(result.stdout).to eq("")
      expect(result.stderr).to include("sh", "downstream of a pipe")
      expect(sink.joined).to include("sh")
    end

    # Two independent defences, and this one does not lean on the other:
    # Shell::Verdict abstains on `sh` by NAME, so the command never reaches here
    # as a term. A term built by any other caller still meets the predicate.
    it "sits behind a verdict that already abstains on the same command" do
      expect(Lain::Shell::Verdict.new.call("echo whoami | sh")).to be_abstain
    end

    # Default-refusing, not denylisting: `ls` executes nothing it reads, and it
    # is still refused downstream, because the list is what a stage must be ON.
    it "refuses a program that is merely absent from the list" do
      expect(run([%w[echo hi], ["ls"]]).exit_status).to eq(126)
    end

    # `rg` was ON this list in this card's first draft, and
    # `echo hi | rg --pre=id foo` verdicts allow, takes the term arm, and runs
    # `id`. Recognising a name is not reading its flags -- which is the whole
    # reason the list is an allowlist. Regression-pinned by name.
    it "refuses ripgrep, which executes a program its own flags name" do
      result = run([%w[echo hi], %w[rg --pre=id foo]])
      expect(result.exit_status).to eq(126)
      expect(result.stderr).to include("rg", "downstream of a pipe")
    end

    it "runs a stdin-safe filter downstream" do
      expect(run([%w[echo hi], ["wc", "-c"]]).stdout.strip).to eq("3")
    end

    # The predicate is about STDIN, so it applies only where a pipe supplies it.
    # A lone stage inherits /dev/null, and judging its program is the verdict's
    # job, not this object's.
    it "does not apply the predicate to the first stage" do
      expect(run([["ls", "-d", "."]]).exit_status).to eq(0)
    end

    # A path is not a name. An allowlist matched on a basename would accept
    # `/tmp/sort`, so a downstream stage must name its program bare.
    it "refuses a downstream program written as a path" do
      expect(run([%w[echo hi], ["/usr/bin/sort"]]).exit_status).to eq(126)
    end
  end

  # A misparse must degrade to a broken command rather than an attacker-chosen
  # one. This is the TERM half of the card's scenario: the exact argv
  # Shell::Parse reconstructs for `time { echo PWNED; }`, run as argv. (The
  # DISPATCH half lives in bash_spec: that command abstains, so it reaches the
  # string arm and the existing gate -- see the note there.)
  describe "a misparsed term" do
    it "does not execute what the braces would have grouped" do
      result = run([%w[time { echo PWNED], ["}"]])
      expect(result.exit_status).not_to eq(0)
      expect(result.stdout).not_to include("PWNED")
      expect(result.stderr).not_to include("PWNED")
    end

    it "degrades a one-stage misparse to a program that cannot run its argument" do
      result = run([%w[time { echo PWNED]])
      expect(result.exit_status).not_to eq(0)
      expect(result.stdout).not_to include("PWNED")
    end
  end

  # Every one of these reaches this object from a Tool::Input the model wrote,
  # so a raise here is an agent-visible crash. `call` is total.
  describe "terms that cannot run, refused rather than raised" do
    it "refuses an empty term" do
      expect(run([]).exit_status).to eq(127)
    end

    it "refuses a term holding an empty argv" do
      expect(run([[]]).exit_status).to eq(127)
    end

    it "refuses an argv holding an empty word" do
      expect(run([["", "x"]]).exit_status).to eq(127)
    end

    # A NUL byte parses CLEAN into an ordinary word (Shell::Parse's own note),
    # and `exec` raises ArgumentError on one. The refusal is what keeps that
    # raise off the agent's turn.
    it "refuses an argument containing a NUL byte" do
      result = run([["echo", "a\0b"]])
      expect(result.exit_status).to eq(127)
      expect(result.stderr).to include("NUL")
    end

    # Not a crash guard: Open3 pops a Hash off a stage and merges it into the
    # SPAWN OPTIONS (`cmd_opts.update cmd.pop if Hash === cmd.last`), so a Hash
    # here would be another chdir, another stdin, an fd redirection.
    it "refuses a stage carrying anything that is not a String" do
      expect(run([["echo", { chdir: "/" }]]).exit_status).to eq(127)
      expect(run([["echo", 3]]).stderr).to include("not a String")
      expect(run([["echo", ["nested"]]]).stderr).to include("not a String")
    end

    # The one window the pre-flight cannot close, forced deterministically: an
    # environment key holding `=` makes `spawn` itself raise. What the refusal
    # must NOT do is read as "nothing ran", because by the time spawn raises for
    # stage N, stages 1..N-1 are already running and detached.
    it "does not claim nothing ran when a stage fails at spawn" do
      result = run([%w[echo hi]], env: { "A=B" => "x" })
      expect(result.exit_status).to eq(127)
      expect(result.stderr).to include("may already have run", "ArgumentError")
    end

    it "refuses a program that does not resolve on PATH" do
      result = run([["lain-no-such-program"]])
      expect(result.exit_status).to eq(127)
      expect(result.stderr).to include("lain-no-such-program", "not found")
    end

    it "refuses a directory named as a program" do
      expect(run([["/tmp"]]).exit_status).to eq(127)
    end

    # Open3 spawns every stage from the PARENT process in sequence, so a stage
    # two that cannot run is discovered only after stage one is already running
    # and detached. Refusing up front is what keeps that from leaking a live
    # process -- and from letting stage one's side effects happen anyway.
    it "runs nothing at all when a later stage will not run" do
      Dir.mktmpdir do |dir|
        marker = File.join(dir, "ran")
        result = run([["touch", marker], ["lain-no-such-program"]])
        expect(result.exit_status).not_to eq(0)
        expect(File).not_to exist(marker)
      end
    end
  end

  describe "the worker environment" do
    it "runs in the given cwd" do
      Dir.mktmpdir do |dir|
        expect(run([["pwd"]], cwd: dir).stdout.strip).to eq(File.realpath(dir))
      end
    end

    # A program written as a relative path resolves after the child's chdir, so
    # the pre-flight has to ask the TERM's cwd about it rather than `Dir.pwd`.
    it "resolves a relative program path against the given cwd" do
      Dir.mktmpdir do |dir|
        script = File.join(dir, "probe.sh")
        File.write(script, "#!/bin/sh\necho ran\n")
        File.chmod(0o755, script)

        expect(run([["./probe.sh"]], cwd: dir).stdout).to eq("ran\n")
      end
    end

    it "exposes an injected env var to the command" do
      result = run([%w[printenv LAIN_PIPE_PROBE]], env: { "LAIN_PIPE_PROBE" => "from_worker_env" })
      expect(result.stdout).to eq("from_worker_env\n")
    end

    # The WorkerEnv contract, unchanged by the arm: `env` is an additive
    # override, and only an explicit nil VALUE scrubs a host var.
    it "leaves a host var the injected env omits in place" do
      ENV["LAIN_PIPE_HOST"] = "leaked"
      expect(run([%w[printenv LAIN_PIPE_HOST]], env: {}).stdout).to eq("leaked\n")
    ensure
      ENV.delete("LAIN_PIPE_HOST")
    end

    it "scrubs a host var mapped to nil" do
      ENV["LAIN_PIPE_SCRUB"] = "leaked"
      result = run([%w[printenv LAIN_PIPE_SCRUB]], env: { "LAIN_PIPE_SCRUB" => nil })
      expect(result.stdout).to eq("")
      expect(result.exit_status).not_to eq(0)
    ensure
      ENV.delete("LAIN_PIPE_SCRUB")
    end

    # `Dir.chdir` fails in mixlib's forked CHILD (exit 1, a ruby backtrace on
    # stderr) and in the parent for `spawn`, where it would be a raise. Refusing
    # up front keeps the two arms' posture the same: an ok result, exit 1, the
    # directory named.
    it "refuses a cwd that does not exist, with the shell arm's exit-1 posture" do
      Dir.mktmpdir do |dir|
        missing = File.join(dir, "missing")
        result = run([["pwd"]], cwd: missing)
        expect(result.exit_status).to eq(1)
        expect(result.stderr).to include(missing)
      end
    end
  end

  # The first stage's stdin is fd 0 of THIS process unless something says
  # otherwise, so without `in: File::NULL` a bare `cat` -- which Shell::Verdict
  # allows -- would read the human's keystrokes at the repl. Nothing else in
  # either spec file fails when that option is deleted, which is exactly why
  # this example exists.
  describe "the first stage's stdin" do
    it "is /dev/null, and never the process's own" do
      read, write = IO.pipe
      write.write("typed by the human\n")
      write.close
      saved = $stdin.dup

      begin
        $stdin.reopen(read)
        expect(run([["cat"]]).stdout).to eq("")
      ensure
        $stdin.reopen(saved)
        [saved, read].each(&:close)
      end
    end
  end

  describe "live streaming" do
    it "writes stdout bytes to the stdout sink as they are produced" do
      sink = RecordingSink.new
      run([%w[printf hi]], stdout_sink: sink)
      expect(sink.joined).to eq("hi")
    end

    it "writes stderr bytes to the stderr sink, and not to the stdout sink" do
      out = RecordingSink.new
      err = RecordingSink.new
      run([["cat", "/nonexistent/lain/probe"]], stdout_sink: out, stderr_sink: err)

      expect(err.joined).to include("/nonexistent/lain/probe")
      expect(out.joined).to eq("")
    end

    it "sends nothing anywhere by default" do
      expect { run([%w[printf hi]]) }.not_to raise_error
    end
  end

  describe "timeout" do
    it "raises Timeout when the term outlives its deadline" do
      expect { run([%w[sleep 5]], timeout: 0.3) }.to raise_error(described_class::Timeout)
    end

    # Mixlib embeds the pre-kill capture in its CommandTimeout message, and the
    # exec-boundary parity group pins that NEITHER arm discards it.
    it "carries the output produced before the kill" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "log")
        File.write(path, "before\n")
        expect { run([["tail", "-f", path]], timeout: 0.3) }
          .to raise_error(described_class::Timeout, /before/)
      end
    end

    # A sink belongs to the caller: Sink::IOAdapter over a channel a detached
    # frontend has closed raises IOError mid-pump. If that escapes without a
    # kill, Open3's ensure joins the wait threads with NO deadline -- measured
    # at 8 seconds and still blocked, under a 2-second timeout.
    # The subject writes ONCE and then blocks: a stage that keeps writing dies of
    # EPIPE on its own when Open3's ensure closes the read end, which would make
    # this example pass whether or not anything killed it.
    it "kills the term when a sink raises mid-pump, rather than joining forever" do
      exploding = Class.new { def <<(_bytes) = raise(IOError, "the frontend detached") }.new
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect { run([["/bin/sh", "-c", "echo x; sleep 30"]], timeout: 30, stdout_sink: exploding) }
        .to raise_error(IOError)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
    end

    it "kills the whole process group rather than leaving it running" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "log")
        File.write(path, "x\n")
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect { run([["tail", "-f", path]], timeout: 0.3) }.to raise_error(described_class::Timeout)
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
      end
    end
  end

  it "is a frozen value, so one instance serves every call" do
    expect(pipeline).to be_frozen
  end
end
