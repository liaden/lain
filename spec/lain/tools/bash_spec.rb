# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Tools::Bash do
  subject(:tool) { described_class.new }

  let(:channel) { RecordingChannel.new }

  def invocation(tool_use_id: "tu_1")
    Lain::Tool::Invocation.new(tool_use_id:, channel:)
  end

  it "runs a command and captures its stdout" do
    result = tool.call({ command: "echo hello" }, invocation)
    expect(result).to be_ok
    expect(result.content).to include("exit status: 0")
    expect(result.content).to include("hello")
  end

  it "captures stderr alongside stdout" do
    result = tool.call({ command: "echo oops 1>&2" }, invocation)
    expect(result.content).to include("oops")
  end

  it "reports a nonzero exit status in the content, not as is_error" do
    # A nonzero exit is often exactly what the model asked to observe (grep
    # with no matches); the tool ran correctly, so this is not a tool failure.
    # `sh -c` in the command keeps this on the STRING arm -- Shell::Verdict
    # abstains on `sh` -- which is where `exit` is a builtin that works.
    result = tool.call({ command: %(sh -c "exit 3") }, invocation)
    expect(result).to be_ok
    expect(result.content).to include("exit status: 3")
  end

  it "reports a nonzero exit status from the term arm too" do
    result = tool.call({ command: "grep -q lain-no-such-pattern /dev/null" }, invocation)
    expect(result).to be_ok
    expect(result.content).to include("exit status: 1")
  end

  it "runs in the given cwd" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "marker.txt"), "here")
      result = tool.call({ command: "ls", cwd: dir }, invocation)
      expect(result.content).to include("marker.txt")
    end
  end

  describe "timeout" do
    # The real process-group kill, end to end: TERM actually hits a live
    # `sleep 5` group and mixlib reaps it. The injected factory only shortens
    # the TERM->KILL grace -- mixlib-shellout hardcodes `sleep 3` inside
    # reap_errant_child with no option to configure it, and 3 idle seconds
    # would dominate the whole suite's runtime.
    #
    # `sh -c` keeps this on the STRING arm, which is the arm mixlib owns; a bare
    # `sleep 5` is literal and would be run as a term.
    it "kills a command that runs past its timeout" do
      short_grace = lambda do |*args, **opts|
        Mixlib::ShellOut.new(*args, **opts).tap do |shell_out|
          def shell_out.sleep(_grace) = super(0.1)
        end
      end

      result = described_class.new(shell_out_factory: short_grace)
                              .call({ command: %(sh -c "sleep 5"), timeout: 1 }, invocation)
      expect(result).to be_error
      expect(result.content).to include("timed out")
    end

    # The same posture on the term arm: a Shell::Pipeline::Timeout is an error
    # Result naming the timeout, exactly as mixlib's CommandTimeout is, because
    # a timeout is the tool failing to produce a result rather than a command
    # exiting non-zero.
    it "kills a term that runs past its timeout" do
      tool = described_class.new(pipeline: Lain::Shell::Pipeline.new(grace: 0.1),
                                 shell_out_factory: ->(*, **) { raise "the term arm must not reach a shell" })

      result = tool.call({ command: "sleep 5", timeout: 1 }, invocation)
      expect(result).to be_error
      expect(result.content).to include("timed out after 1s")
    end

    # The rescue->Result mapping in isolation: no subprocess, no clock.
    it "maps CommandTimeout to an error Result naming the timeout" do
      timed_out = Class.new do
        def run_command = raise Mixlib::ShellOut::CommandTimeout, "Command timed out after 7s"
      end
      tool = described_class.new(shell_out_factory: ->(*, **) { timed_out.new })

      result = tool.call({ command: %(sh -c "sleep 5"), timeout: 7 }, invocation)
      expect(result).to be_error
      expect(result.content).to include("timed out after 7s")
    end
  end

  describe "attributed live streaming" do
    it "emits stdout bytes as Telemetry::ToolOutput carrying the invocation's tool_use_id and stream" do
      tool.call({ command: "echo from_stdout" }, invocation(tool_use_id: "tu_abc"))

      stdout_events = channel.events.select { |e| e.stream == :stdout }
      expect(stdout_events).not_to be_empty
      expect(stdout_events).to all(be_a(Lain::Telemetry::ToolOutput))
      expect(stdout_events).to all(have_attributes(tool_use_id: "tu_abc"))
      expect(stdout_events.map(&:bytes).join).to include("from_stdout")
    end

    it "emits stderr bytes on the :stderr stream, distinct from stdout" do
      tool.call({ command: "echo to_err 1>&2" }, invocation(tool_use_id: "tu_xyz"))

      stderr_events = channel.events.select { |e| e.stream == :stderr }
      expect(stderr_events).not_to be_empty
      expect(stderr_events).to all(have_attributes(tool_use_id: "tu_xyz"))
      expect(stderr_events.map(&:bytes).join).to include("to_err")
    end
  end

  it "does nothing observable when no channel is injected (Null Object default)" do
    bare = Lain::Tool::Invocation.new(tool_use_id: "tu_1")
    expect { tool.call({ command: "echo quiet" }, bare) }.not_to raise_error
  end

  # The WorkerEnv the Session lends: the default is byte-identical to today
  # (process ENV + Dir.pwd), an injected one isolates env and cwd.
  describe "worker env (session-lent env and cwd)" do
    def invocation_with(session)
      Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session, channel:)
    end

    it "inherits the process env under the default WorkerEnv" do
      ENV["LAIN_WE_PROBE"] = "from_process"
      result = tool.call({ command: "echo $LAIN_WE_PROBE" }, invocation_with(Lain::Session.new))
      expect(result.content).to include("from_process")
    ensure
      ENV.delete("LAIN_WE_PROBE")
    end

    it "exposes an injected env var to the command" do
      env = ENV.to_h.merge("DATABASE_URL" => "postgres://sandbox/db")
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: Dir.pwd, env:))
      result = tool.call({ command: "echo $DATABASE_URL" }, invocation_with(session))
      expect(result.content).to include("postgres://sandbox/db")
    end

    it "runs in the WorkerEnv cwd when the input names none" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "marker.txt"), "here")
        session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env: ENV.to_h))
        result = tool.call({ command: "ls" }, invocation_with(session))
        expect(result.content).to include("marker.txt")
      end
    end

    it "resolves a relative input cwd against the WorkerEnv cwd" do
      Dir.mktmpdir do |dir|
        Dir.mkdir(File.join(dir, "sub"))
        File.write(File.join(dir, "sub", "inner.txt"), "x")
        session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env: ENV.to_h))
        result = tool.call({ command: "ls", cwd: "sub" }, invocation_with(session))
        expect(result.content).to include("inner.txt")
      end
    end

    # WorkerEnv is an OVERRIDE, not confinement (B3's foundation): mixlib applies
    # `environment:` per-key onto the child's already-inherited ENV and never
    # clears it, so a host var the injected env omits still reaches the command.
    # This pins that true behavior -- probe tmp/b1-probes/env_semantics.rb.
    it "leaks a host env var the injected WorkerEnv omits (additive override, not confinement)" do
      ENV["LAIN_HOST_ONLY"] = "leaked"
      curated = { "DATABASE_URL" => "postgres://sandbox" } # deliberately omits LAIN_HOST_ONLY
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: Dir.pwd, env: curated))

      result = tool.call({ command: "echo host=[$LAIN_HOST_ONLY]" }, invocation_with(session))

      expect(result.content).to include("host=[leaked]")
    ensure
      ENV.delete("LAIN_HOST_ONLY")
    end

    # The sanctioned scrub: an explicit nil VALUE (not an absent key) removes a
    # var, because mixlib's child does `ENV[k] = nil`, and Ruby's `ENV[k] = nil`
    # deletes. WorkerEnv preserves the nil marker through make_shareable.
    it "scrubs a host env var mapped to nil in the injected WorkerEnv" do
      ENV["LAIN_SCRUB_ME"] = "leaked"
      scrubbed = ENV.to_h.merge("LAIN_SCRUB_ME" => nil)
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: Dir.pwd, env: scrubbed))

      result = tool.call({ command: "echo host=[$LAIN_SCRUB_ME]" }, invocation_with(session))

      expect(result.content).to include("host=[]")
    ensure
      ENV.delete("LAIN_SCRUB_ME")
    end

    it "runs a TERM in the WorkerEnv's cwd and environment" do
      Dir.mktmpdir do |dir|
        env = ENV.to_h.merge("LAIN_TERM_PROBE" => "from_worker_env")
        session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env:))

        expect(tool.call({ command: "pwd" }, invocation_with(session)).content).to include(File.realpath(dir))
        expect(tool.call({ command: "printenv LAIN_TERM_PROBE" }, invocation_with(session)).content)
          .to include("from_worker_env")
      end
    end
  end

  # Which arm ran is a decision of Shell::Verdict's, and the tool's job is to
  # make it invisible in the result. These examples pin the choice, not the
  # execution -- Shell::Pipeline's own spec owns what a term does once chosen.
  describe "choosing an arm" do
    # A verdict stand-in that abstains on everything, which is how a command the
    # real verdict would ALLOW can be run through the string arm for comparison.
    let(:abstaining) do
      ->(_command) { Lain::Shell::Verdict::Decision.new(name: :abstain, reason: "pinned", term: []) }
    end

    let(:no_shell) { ->(*, **) { raise "a shell was spawned" } }

    it "runs an allowed command as a term, with no shell process at all" do
      result = described_class.new(shell_out_factory: no_shell).call({ command: "printf hi" }, invocation)

      expect(result).to be_ok
      expect(result.content).to include("exit status: 0", "hi")
    end

    # The dispatch half of the card's misparse scenario. `time { echo PWNED; }`
    # is broken=false and fully covered -- neither the node-kind tier nor the
    # byte-coverage backstop sees anything -- so it abstains via the program-
    # runner denylist and reaches the STRING arm and the gate above it, exactly
    # as it does today. What the reconstructed argv would have done instead is
    # pinned in spec/lain/shell/pipeline_spec.rb.
    it "sends an abstained command to the shell arm, as the original string" do
      seen = []
      recording = lambda do |command, **opts|
        seen << command
        Mixlib::ShellOut.new("true", **opts)
      end

      described_class.new(shell_out_factory: recording).call({ command: "time { echo PWNED; }" }, invocation)
      described_class.new(shell_out_factory: recording).call({ command: "echo $(id)" }, invocation)

      expect(seen).to eq(["time { echo PWNED; }", "echo $(id)"])
    end

    # The flag describes the TOOL, which still takes a string the model wrote.
    # A term arm is not a reason to flip it; which CALLS may skip a human is the
    # escalation ladder's question, asked per call.
    it "still declares that it requires approval" do
      expect(tool.requires_approval?).to be(true)
    end

    # Byte-identity is what keeps the term arm a transparent optimization rather
    # than a behavior change: same exit status, same stdout, same stderr, same
    # encoding, through the one shared template.
    it "renders byte-identical content on either arm" do
      ["printf hi", "grep -q lain-no-such-pattern /dev/null", "cat /nonexistent/lain/probe",
       "ls -d ."].each do |command|
        term = described_class.new.call({ command: }, invocation)
        string = described_class.new(verdict: abstaining).call({ command: }, invocation)

        expect(term.content).to eq(string.content), command
        expect(term.content.encoding).to eq(string.content.encoding), command
        expect(term.is_error).to eq(string.is_error), command
      end
    end

    # The one measured divergence, pinned rather than hidden: a shell BUILTIN
    # has no binary to exec, so the term arm reports 127 where `sh -c` exits 3.
    # Implementing builtins would make Shell::Pipeline a shell, and re-running
    # the string after an allow would surrender the property the term arm exists
    # for -- so this is the honest outcome, and a reader meets it here.
    it "answers a shell builtin with command-not-found on the term arm" do
      expect(tool.call({ command: "exit 3" }, invocation).content).to include("exit status: 127", "exit")
      expect(described_class.new(verdict: abstaining).call({ command: "exit 3" }, invocation).content)
        .to include("exit status: 3")
    end
  end

  # T5: a command's output is a whole artifact -- its first N bytes read like
  # the answer and are not -- so an oversized one is REFUSED, and the refusal
  # keeps the one fact truncation would have kept: the exit status.
  #
  # The bound lives in .render_output because that is the single rendering BOTH
  # exec arms go through (Bash's two, and CoreExec's daemon reply), so it
  # cannot be applied to one arm and missed on another.
  describe "refusing output too large to hand back" do
    let(:ceiling) { Lain::Tools::Bash::OUTPUT_BOUND.limit }
    let(:oversized_file) do
      File.join(@tmpdir, "big.txt").tap { |path| File.write(path, "x" * (ceiling + 1024)) }
    end
    let(:abstaining) do
      ->(_command) { Lain::Shell::Verdict::Decision.new(name: :abstain, reason: "pinned", term: []) }
    end

    around do |example|
      Dir.mktmpdir do |dir|
        @tmpdir = dir
        example.run
      end
    end

    # `tr` over /dev/zero rather than `yes | head`: an exact byte count, and no
    # SIGPIPE race to make the size depend on scheduling.
    def flooding(bytes, char = "x") = "head -c #{bytes} /dev/zero | tr '\\0' #{char}"

    it "refuses output over the ceiling, naming its size and the ceiling" do
      result = tool.call({ command: flooding(ceiling + 1024) }, invocation)

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include((ceiling + 1024).to_s, ceiling.to_s)
    end

    it "keeps the exit status a refused command reported" do
      result = tool.call({ command: "#{flooding(ceiling + 1024)}; exit 3" }, invocation)

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include("exit status: 3")
    end

    it "carries none of the refused output" do
      result = tool.call({ command: flooding(ceiling + 1024, "S") }, invocation)

      expect(result.content).not_to include("SS")
    end

    it "names a narrower action rather than leaving the model to re-run it" do
      content = tool.call({ command: flooding(ceiling + 1024) }, invocation).content

      expect(content).to match(/head|tail|grep/)
      expect(content).to include("read_file")
    end

    it "counts stdout and stderr together, since both ride the one result" do
      half = (ceiling / 2) + 1024
      command = "#{flooding(half)}; #{flooding(half, "y")} 1>&2"

      expect(tool.call({ command: }, invocation)).to have_attributes(is_error: true)
    end

    it "leaves output under the ceiling untouched" do
      result = tool.call({ command: flooding(1024) }, invocation)

      expect(result).to be_ok
      expect(result.content).to include("exit status: 0", "x" * 1024)
    end

    # AC4, and the reason the bound is in .render_output rather than in either
    # arm: the same oversized command through the term arm and the string arm
    # must refuse with the same bytes, exactly as a permitted one returns the
    # same bytes (the byte-identity example above).
    it "refuses byte-identically on either arm" do
      command = "cat #{oversized_file}"

      term = described_class.new.call({ command: }, invocation)
      string = described_class.new(verdict: abstaining).call({ command: }, invocation)

      expect(term.content).to eq(string.content)
      expect(term.content.encoding).to eq(string.content.encoding)
      expect(term.is_error).to eq(string.is_error)
      expect(term).to have_attributes(is_error: true)
    end

    # The daemon arm reaches the same ceiling because it reaches the same
    # method: {Tools::CoreExec} renders the wire's fields through this one
    # entry point, so there is no second place for the bound to be missing
    # from.
    it "refuses through the shared rendering the daemon arm also calls" do
      rendered = described_class.render_output(exit_status: 3, stdout: "x" * (ceiling + 1), stderr: "")

      expect(rendered).to have_attributes(is_error: true)
      expect(rendered.content).to include("exit status: 3", (ceiling + 1).to_s)
    end
  end
end
