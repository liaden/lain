# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe Lain::Exec::Sandboxed do
  around do |example|
    Dir.mktmpdir("lain-sandboxed", example.metadata.fetch(:under, Dir.tmpdir)) do |dir|
      @base = File.realpath(dir)
      FileUtils.mkdir_p([File.join(@base, "project"), File.join(@base, "home")])
      example.run
    end
  end

  let(:root) { File.join(@base, "project") }
  let(:home) { File.join(@base, "home") }
  let(:journal) { [] }

  def ruling(rung, rule: nil) = Lain::Approval::Escalation::Ruling.allow(rung:, because: "approved", rule:)

  def executable(name, realpath, klass)
    Lain::Shell::Executable.new(name:, resolved: realpath, realpath:, chain: [], shadowed: [], anomalies: [],
                                klass:, fresh: false, run_files: [], wrappers: [])
  end

  def composed(executables: [executable("cat", "/usr/bin/cat", :system)])
    Lain::Confine::Request.new(ruling: ruling("rules", rule: "composed_term"), executables:, cwd: root, root:,
                               tool_use_id: "toolu_1")
  end

  def judged
    Lain::Confine::Request.new(ruling: ruling("judge"), executables: [], cwd: root, root:, tool_use_id: "toolu_1")
  end

  def recorded(type) = journal.select { _1.journal_type == type }

  describe "with its collaborators doubled" do
    let(:profile) { Lain::Confine::Profile.reader(root:, home:) }
    let(:profiles) { Struct.new(:profile) { def for(_request) = profile }.new(profile) }
    let(:launcher) { Lain::Confine::Bwrap.new(fence: "/x/lain-fence") }
    let(:inner) { inner_class.new }
    let(:sandboxed) { described_class.new(inner:, launcher:, profiles:, journal:, ceiling: 4096) }

    let(:inner_class) do
      Class.new do
        attr_reader :calls
        attr_accessor :behaviour

        def initialize
          @calls = []
          @behaviour = ->(**) { Lain::Exec::Capture.new(exit_status: 0, stdout: "", stderr: "") }
        end

        def takes_term?(term) = term.stages.size == 1

        def call(**kwargs)
          @calls << kwargs
          behaviour.call(**kwargs)
        end
      end
    end

    def run(command: Lain::Shell::Term.of(%w[cat README.md]), timeout: 5, confinement: composed)
      sandboxed.call(command:, cwd: root, env: {}, timeout:, confinement:)
    end

    it "answers for a term as its inner exec does" do
      piped = Lain::Shell::Term.of(%w[cat a], %w[head -1])
      expect([sandboxed.takes_term?(Lain::Shell::Term.of(%w[cat a])), sandboxed.takes_term?(piped)])
        .to eq([true, false])
    end

    it "runs nothing when a program the call resolved to lies outside what the profile may run" do
      planted = File.join(root, "bin/cat")
      capture = run(confinement: composed(executables: [executable("cat", planted, :project)]))

      expect(inner.calls).to be_empty
      expect(capture).to have_attributes(exit_status: 126, stdout: "")
      expect(capture.stderr).to include(planted)
      expect(recorded("exec_record").sole).to have_attributes(execs: [], refusals: [], fd_execs: [])
      expect(recorded("sandbox").sole).to have_attributes(profile: :reader, refused: [planted])
    end

    it "runs nothing when a wrapper the call resolved to lies outside what the profile may run" do
      planted = File.join(root, "bin/nice")
      wrapped = Lain::Shell::Executable.unresolved("cat", wrappers: [executable("nice", planted, :project)])

      capture = run(confinement: composed(executables: [wrapped]))

      expect([inner.calls, capture.exit_status, recorded("sandbox").sole.refused]).to eq([[], 126, [planted]])
    end

    it "bounds its refusal by the ceiling it was given" do
      capture = run(confinement: composed(executables: [executable("cat", File.join(root, "bin/cat"), :project)]))
      expect(capture.ceiling).to eq(4096)
    end

    it "hands the trace to descriptor 3 and wraps the term the preflight has already read" do
      run

      handed = inner.calls.sole
      expect(handed[:fds].keys).to eq([3])
      expect(handed[:launch].call(Lain::Shell::Term.of(%w[cat README.md])).stages.sole.argv.first)
        .to eq("/usr/bin/bwrap")
    end

    it "closes its trace writers and journals the trace when the call times out" do
      inner.behaviour = ->(**) { raise Lain::Exec::Timeout, "too slow" }

      expect { run }.to raise_error(Lain::Exec::Timeout, "too slow")
      expect(inner.calls.sole[:fds].fetch(3)).to be_closed
      expect(recorded("exec_record").sole).to have_attributes(truncated: false, incomplete: false)
    end

    def capture = Lain::Exec::Capture.new(exit_status: 0, stdout: "", stderr: "")

    def writing(*lines)
      inner.behaviour = lambda do |fds:, **|
        fds.fetch(3).write(lines.map { "#{_1}\n" }.join)
        capture
      end
    end

    it "reads what the trace holds once the call is over" do
      writing('10 execve("/usr/bin/cat", ["cat"], 0x0 /* 0 vars */) = 0')
      run

      expect(recorded("exec_record").sole)
        .to have_attributes(execs: [{ path: "/usr/bin/cat", argv0: "cat", rc: 0 }], incomplete: false)
    end

    describe "wording a refusal the trace recorded" do
      let(:planted) { File.join(root, "bin/x") }
      let(:wording) { format(described_class::REFUSED, path: planted) }

      def refused_exec(path) = %(10 execve("#{path}", ["x"], 0x0 /* 0 vars */) = -1 EACCES (Permission denied))
      def ran_exec(path) = %(11 execve("#{path}", ["x"], 0x0 /* 0 vars */) = 0)

      it "ends the output with the refusal for an exec the sandbox refused" do
        writing(refused_exec(planted))

        expect(run.stderr).to end_with("#{wording}\n")
      end

      it "adds nothing to a call with no refusal" do
        writing(ran_exec("/usr/bin/cat"))

        expect(run.stderr).not_to include("REFUSED")
      end

      it "treats a refusal followed by a successful exec of the same program as search noise" do
        writing(refused_exec(planted), ran_exec("/usr/bin/x"))

        expect(run.stderr).not_to include("REFUSED")
      end

      it "words a refusal that no later exec of the program answered, beside one that did" do
        writing(refused_exec(planted), refused_exec("/other/y"), ran_exec("/usr/bin/y"))

        expect(run.stderr).to end_with("#{wording}\n").and(satisfy { !_1.include?("/other/y") })
      end

      it "words a refusal that an unrelated successful exec of the same program came before" do
        inner.behaviour = lambda do |fds:, **|
          fds.fetch(3).write("#{ran_exec("/usr/bin/x")}\n")
          fds.fetch(4).write("#{refused_exec(planted)}\n")
          capture
        end

        expect(run(command: Lain::Shell::Term.of(%w[x a], %w[x b])).stderr).to end_with("#{wording}\n")
      end

      it "shows a path holding a newline on one line, so it cannot forge another" do
        forged = "#{planted}\nforged"
        writing(refused_exec(forged.gsub("\n", "\\n")))

        stderr = run.stderr
        expect(stderr).to include(format(described_class::REFUSED, path: "#{planted}\\nforged"))
        expect(stderr.lines.size).to eq(1)
      end

      def loud(stdout, exit_status: 3, size: stdout.bytesize)
        inner.behaviour = lambda do |fds:, **|
          fds.fetch(3).write("#{refused_exec(planted)}\n")
          Lain::Exec::Capture.new(exit_status:, stdout:, stderr: "", size:, ceiling: 4096)
        end
      end

      it "keeps the line visible when it would push an output just under the ceiling over it" do
        loud("a" * 4000)
        capture = run

        expect(capture).to have_attributes(exit_status: 3, stdout: "", stderr: a_string_ending_with("#{wording}\n"))
        expect(Lain::Tools::Bash.render_output(capture)).to be_ok
      end

      it "keeps the line visible when the output is already over the ceiling" do
        loud("a" * 4097, size: 9000)
        capture = run

        expect(capture).to have_attributes(exit_status: 3, stdout: "", stderr: a_string_ending_with("#{wording}\n"))
        expect(Lain::Tools::Bash.render_output(capture)).to be_ok
      end

      it "counts the added line in the capture's size" do
        writing(refused_exec(planted))
        capture = run

        expect(capture.size).to eq(capture.stdout.bytesize + capture.stderr.bytesize)
      end

      it "words nothing under a trace that confines nothing" do
        traced = Struct.new(:profile) { def for(_request) = profile }.new(Lain::Confine::Profile::TRACED)
        writing(refused_exec(planted))

        auditing = described_class.new(inner:, launcher:, profiles: traced, journal:)
        capture = auditing.call(command: Lain::Shell::Term.of(%w[cat a]), cwd: root, env: {}, timeout: 5,
                                confinement: judged)

        expect(capture.stderr).not_to include("REFUSED")
      end
    end

    it "hands each stage its own descriptor and merges their records in stage order" do
      inner.behaviour = lambda do |fds:, **|
        fds.fetch(4).write(%(20 execve("/usr/bin/head", ["head"], 0x0 /* 0 vars */) = 0\n))
        fds.fetch(3).write(%(10 execve("/usr/bin/cat", ["cat"], 0x0 /* 0 vars */) = 0\n))
        capture
      end
      run(command: Lain::Shell::Term.of(%w[cat README.md], %w[head -1]))

      expect(inner.calls.sole[:fds].keys).to eq([3, 4])
      expect(recorded("exec_record").sole.execs.map { _1[:path] }).to eq(%w[/usr/bin/cat /usr/bin/head])
    end

    # Truncated keeps meaning the cap; an exec whose line never closed is a different fact.
    it "journals the trace as incomplete when an exec never closes" do
      writing('10 execve("/usr/bin/cat", ["cat"], 0x0 /* 0 vars */ <unfinished ...>')
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      run(timeout: 30)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
      expect(recorded("exec_record").sole).to have_attributes(truncated: false, incomplete: true)
    end

    it "waits a bounded time for an exec to close after the call, and journals it complete when it does" do
      late = []
      inner.behaviour = lambda do |fds:, **|
        writer = fds.fetch(3).dup
        writer.write("10 execve(\"/usr/bin/cat\", [\"cat\"], 0x0 /* 0 vars */ <unfinished ...>\n")
        late << Thread.new do
          sleep 0.2
          writer.write("10 <... execve resumed>) = 0\n10 +++ exited with 0 +++\n")
        ensure
          writer.close
        end
        capture
      end

      run
      late.each(&:join)

      expect(recorded("exec_record").sole).to have_attributes(incomplete: false, execs: [a_hash_including(rc: 0)])
    end

    context "when journalling the trace fails" do
      let(:journal) do
        Class.new(Array) do
          def <<(record)
            raise IOError, "journal is gone" if record.journal_type == "exec_record"

            super
          end
        end.new
      end

      it "raises that failure from a call that otherwise ran clean" do
        expect { run }.to raise_error(IOError, "journal is gone")
      end

      it "leaves the call's own timeout to reach the caller" do
        inner.behaviour = ->(**) { raise Lain::Exec::Timeout, "too slow" }
        expect { run }.to raise_error(Lain::Exec::Timeout, "too slow")
      end
    end
  end

  describe "as an exec backend over a real Local" do
    let(:backend) do
      described_class.new(inner: Lain::Exec::Local.new, launcher: Lain::Confine::Bwrap.new(fence: "/x/lain-fence"),
                          profiles: Struct.new(:none) { def for(_request) = none }.new(Lain::Confine::Profile::NONE),
                          journal:)
    end

    def run_term(term) = backend.call(command: term, cwd: Dir.pwd, env: {}, timeout: 10)
    def terms_taken = [Lain::Shell::Term.of(%w[printf hi]), Lain::Shell::Term.of(%w[printf hi], %w[cat])]
    def terms_refused = []

    it_behaves_like "an exec backend answering for a term"
  end

  describe "on this box", :seam do
    let(:fence) { Lain::Confine::Bwrap.fence_binary }
    let(:policy) do
      Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root))
    end
    let(:runner) do
      lambda do |argv|
        out, status = Open3.capture2e(*argv)
        [out, status.success?]
      end
    end
    let(:probe) { Lain::Confine::Probe.new(fence:, journal:, runner:) }
    let(:sandboxed) do
      described_class.new(
        inner: Lain::Exec::Local.new, launcher: Lain::Confine::Bwrap.new(fence:), journal:,
        profiles: Lain::Confine::Profiles.new(
          masks: Lain::Confine::MaskList.new(root:, policy: -> { policy }), probe:, home: Dir.home, root:
        )
      )
    end

    before do
      skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
      skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
      skip("bwrap cannot make a user namespace on this host") unless
        system("/usr/bin/bwrap", "--ro-bind", "/", "/", "--", "true", %i[out err] => File::NULL)

      SeedRepo.git(root, "init", "-q")
      File.write(File.join(root, "README.md"), "the readme\n")
    end

    def run(command, confinement: composed, env: {}, timeout: 10)
      sandboxed.call(command:, cwd: root, env: { "LC_ALL" => "C", **env }, timeout:, confinement:)
    end

    def term(*argvs) = Lain::Shell::Term.of(*argvs)

    it "runs a ComposedTerm approval under the reader profile, and journals what it ran" do
      expect(run(term(%w[cat README.md]))).to have_attributes(exit_status: 0, stdout: "the readme\n")
      expect(recorded("sandbox").sole).to have_attributes(tool_use_id: "toolu_1", profile: :reader, trace: true)
      expect(recorded("exec_record").sole.execs).to include(a_hash_including(path: "/usr/bin/cat", rc: 0))
    end

    it "hides a secret that appeared after the sandbox was built" do
      sandboxed
      File.write(File.join(root, ".env"), "SECRET=1\n")

      expect(run(term(%w[cat .env])).stdout).not_to include("SECRET")
    end

    context "when a program is planted on PATH after the call was resolved" do
      let(:planted) { File.join(root, "bin", "cat") }
      let(:path) { { "PATH" => "#{File.dirname(planted)}:/usr/bin:/bin" } }

      before do
        FileUtils.mkdir_p(File.dirname(planted))
        File.write(planted, "#!/bin/sh\necho planted\n")
        File.chmod(0o755, planted)
      end

      it "is refused by the kernel when the shell execs it" do
        capture = run("cat README.md", env: path)

        expect(capture.stdout).not_to include("planted")
        expect(recorded("exec_record").sole.refusals).to include({ path: planted, errno: "EACCES" })
      end

      it "tells the model the refusal is final when the program had no other copy to fall through to" do
        expect(run("cat README.md", env: { "PATH" => File.dirname(planted) }).stderr)
          .to end_with("#{format(described_class::REFUSED, path: planted)}\n")
      end

      it "is refused when a term's stage execs it, which then falls through to the next PATH entry" do
        expect(run(term(%w[cat README.md]), env: path).stdout).to eq("the readme\n")
        expect(recorded("exec_record").sole.refusals).to include({ path: planted, errno: "EACCES" })
      end
    end

    it "traces a judge's approval without confining it" do
      expect(run(term(["cat", __FILE__]), confinement: judged).exit_status).to eq(0)
      expect(recorded("sandbox").sole).to have_attributes(profile: :traced, trace: true)
      expect(recorded("exec_record").sole.execs).to include(a_hash_including(path: "/usr/bin/cat"))
    end

    it "runs a piped term under the reader profile and under the trace alone" do
      [composed, judged].each do |confinement|
        expect(run(term(%w[cat README.md], %w[head -1]), confinement:))
          .to have_attributes(exit_status: 0, stdout: "the readme\n")
      end
    end

    it "still names a missing program as not found" do
      expect(run(term(%w[no-such-program-anywhere])))
        .to have_attributes(exit_status: 127, stderr: "lain: no-such-program-anywhere: command not found\n")
    end

    it "keeps bundler from reading the user's own config, which may hold gem credentials" do
      expect(run(term(%w[printenv BUNDLE_USER_CONFIG])).stdout).to eq("/dev/null\n")
    end

    it "leaves nothing alive in the sandbox once a timeout has killed the call" do
      marker = "30.#{Process.pid}#{rand(1000)}"

      expect { run("sleep #{marker}", timeout: 1) }.to raise_error(Lain::Exec::Timeout)
      expect(system("pgrep", "-f", "sleep #{marker}", out: File::NULL)).to be(false)
    end

    # The traced command inherits none of the trace descriptors, so it cannot write lines of its own into them.
    it "keeps a traced command from adding an exec to its record, or hiding one" do
      forged = %(printf 'execve("/usr/lib/forged", ["forged"], 0x0 /* 0 vars */) = 0\\n' >&3)
      run("#{forged}; printf x >&3; /usr/bin/id -u", confinement: judged)

      paths = recorded("exec_record").sole.execs.map { _1[:path] }
      expect(paths).to include("/usr/bin/id")
      expect(paths).not_to include("/usr/lib/forged")
    end

    describe "a command that leaves a background process behind" do
      let(:marker) { "30#{rand(1000)}.#{Process.pid}" }

      def alive?(pattern) = system("pgrep", "-f", pattern, out: File::NULL)

      def took
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end

      after { system("pkill", "-f", "sleep #{marker}") }

      it "returns once the traced command exits, leaves the process running, and lists the command's execs" do
        seconds = took do
          expect(run("nohup sleep #{marker} >/dev/null 2>&1 & /usr/bin/true; echo started", confinement: judged).stdout)
            .to eq("started\n")
        end
        sleep 0.2

        expect(seconds).to be < 2
        expect(alive?("^sleep #{marker}")).to be(true)
        expect(recorded("exec_record").sole.execs).to include(a_hash_including(path: "/usr/bin/true", rc: 0))
      end

      it "returns once the traced command exits, even while its child holds the output open" do
        expect(took { run("sleep 3 & echo hi", confinement: judged) }).to be < 2
      end

      # bwrap's pid namespace ends with the call, so the reader's children end with it.
      it "returns once a reader command exits, and its child ends with it" do
        expect(took { run("sleep #{marker} & echo hi") }).to be < 2
        sleep 0.2
        expect(alive?("sleep #{marker}")).to be(false)
      end

      it "times a traced call out within its deadline and the pipeline's grace" do
        seconds = took do
          expect { run("setsid sleep #{marker} & sleep #{marker}1", confinement: judged, timeout: 1) }
            .to raise_error(Lain::Exec::Timeout)
        end

        expect(seconds).to be < 1 + Lain::Shell::Pipeline::DEFAULT_GRACE
      end
    end

    it "records the exec of every stage of a three-stage term, run after run" do
      File.write(File.join(root, "f"), "a\nb\n")
      programs = %w[/usr/bin/cat /usr/bin/head /usr/bin/wc]
      [composed(executables: []), judged].each do |confinement|
        lost = Array.new(20) do
          journal.clear
          run(term(%w[cat f], %w[head -1], %w[wc -l]), confinement:)
          paths = recorded("exec_record").sole.execs.select { _1[:rc].zero? }.map { _1[:path] }
          programs - paths
        end
        expect(lost.flatten).to be_empty
      end
    end

    it "records a path longer than strace's default string limit whole" do
      long = File.join(root, "a-program-name-well-past-thirty-two-bytes")
      File.symlink("/usr/bin/true", long)

      run(term([long]), confinement: judged)

      expect(recorded("exec_record").sole.execs).to include(a_hash_including(path: long, rc: 0))
    end

    # An unlinked file is invisible to a listing, so ask which process still holds one.
    def held_under(dir) = Dir.glob("/proc/[0-9]*/fd/*").filter_map { link(_1) }.select { _1.start_with?("#{dir}/") }

    def link(path)
      File.readlink(path)
    rescue SystemCallError
      nil
    end

    # An undrained pipe would stall the tracer, and so the loop, after about 270 iterations.
    it "keeps a background process the traced call left running at full speed, and holds no file in TMPDIR" do
      calltmp = File.join(@base, "calltmp")
      count = File.join(@base, "count")
      FileUtils.mkdir_p(calltmp)
      loop_body = "n=0; while :; do /usr/bin/true; n=$((n+1)); echo $n > #{count}; done"
      run("nohup sh -c '#{loop_body}' >/dev/null 2>&1 & echo started",
          confinement: judged, env: { "TMPDIR" => calltmp })
      sleep 1
      before = File.read(count).to_i
      sleep 2

      expect(File.read(count).to_i - before).to be > 200
      expect(held_under(calltmp)).to be_empty
    ensure
      system("pkill", "-f", count)
    end

    context "when this kernel cannot trace" do
      let(:runner) do
        real = super()
        ->(argv) { File.basename(argv.first) == "strace" ? ["", false] : real.call(argv) }
      end

      it "still confines a reader call, and records that it ran untraced" do
        expect(run(term(%w[cat README.md])).stdout).to eq("the readme\n")
        expect(run(term(["cat", __FILE__])).exit_status).not_to eq(0)
        expect(recorded("sandbox").map(&:trace)).to eq([false, false])
        expect(recorded("exec_record")).to be_empty
      end
    end
  end
end
