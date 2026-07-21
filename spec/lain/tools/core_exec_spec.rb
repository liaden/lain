# frozen_string_literal: true

require "async"
require "fileutils"
require "tmpdir"

# Fix-4 fixture, kept out of any RSpec block (Lint/ConstantDefinitionInBlock):
# a client duck that accepts the call and never replies -- the wire shape of a
# daemon that failed to enforce its own timeout (pre-3b8c047, pipe-holding
# grandchildren produced exactly this: a 0.5s timeout held for 5.0s).
module CoreExecSpecSupport
  class NeverReplies
    def call(_method, _params)
      Async::Task.current.sleep(3600)
    end
  end
end

# C3: the differential arm of the exec boundary. Tools::CoreExec runs the SAME
# `sh -c` command shape as Tools::Bash, but out of process through the
# lain-core daemon -- and the card's whole point is that the two transports are
# byte-for-byte indistinguishable in their Tool::Result content. The :core
# examples drive the REAL compiled daemon (`bundle exec rake core:build`); the
# shape examples run everywhere and pin the Input-sharing that keeps the
# differential honest.
RSpec.describe Lain::Tools::CoreExec do
  describe "shape" do
    # Construction-only: these examples never dispatch, so the client is a
    # verifying double that would fail loudly if any message reached it.
    let(:tool) { described_class.new(client: instance_double(Lain::Core::Client)) }

    it "shares Bash's Input class by IDENTITY, so the two schemas cannot drift" do
      expect(described_class.input_model).to be(Lain::Tools::Bash::Input)
      expect(tool.input_schema).to eq(Lain::Tools::Bash.new.input_schema)
    end

    it "is tier 3: the model controls the command string, so approval is required" do
      expect(tool.requires_approval?).to be(true)
    end

    it "names itself core_exec" do
      expect(tool.name).to eq("core_exec")
    end
  end

  describe "the client-side deadline backstop" do
    it "returns an error naming the unenforced timeout when the boundary never replies" do
      tool = described_class.new(client: CoreExecSpecSupport::NeverReplies.new, grace: 0.2)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Sync do |task|
        # The outer bound exists so a REGRESSION fails as a raise instead of
        # hanging the suite; the elapsed assertion proves the tool's own
        # backstop fired first, well inside it.
        task.with_timeout(5) { tool.call({ command: "echo hi", timeout: 1 }, Lain::Tool::Invocation.new) }
      end
      expect(result).to be_error
      expect(result.content).to include("failed to enforce", "1s")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
    end
  end

  describe "against the real daemon", :core do
    let(:runtime_base) { Dir.mktmpdir("lain-core-exec") }
    let(:paths) { Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => runtime_base }) }
    let(:workdir) { Dir.mktmpdir("lain-core-exec-cwd") }

    after do
      FileUtils.rm_rf(runtime_base)
      FileUtils.rm_rf(workdir)
    end

    def with_client
      Sync do
        client = Lain::Core::Client.start(paths:)
        begin
          yield client
        ensure
          client.stop
        end
      end
    end

    def invocation(worker_env)
      Lain::Tool::Invocation.new(context: Lain::Session.new(worker_env:))
    end

    # The same command through both transports under ONE WorkerEnv; the pair
    # of results, bash's first.
    def differential(command, worker_env, **input_extra)
      call = invocation(worker_env)
      with_client do |client|
        [Lain::Tools::Bash.new.call({ command:, **input_extra }, call),
         described_class.new(client:).call({ command:, **input_extra }, call)]
      end
    end

    # Byte-for-byte is the contract, so compare the .b forms: encodings may
    # legitimately differ (mixlib tags ASCII-only output UTF-8; the wire's
    # msgpack bin is always BINARY), and String#== on differently-encoded
    # non-ASCII strings is false even when every byte agrees.
    def expect_identical(bash, core)
      expect(core.error?).to eq(bash.error?)
      expect(core.content.b).to eq(bash.content.b)
    end

    it "matches bash byte-for-byte on a text command, cwd threaded through the WorkerEnv" do
      worker_env = Lain::WorkerEnv.new(cwd: workdir, env: {})
      bash, core = differential("pwd -P; echo err >&2; exit 3", worker_env)
      expect_identical(bash, core)
      expect(core.content).to start_with("exit status: 3\n")
      expect(core.content.b).to include(File.realpath(workdir).b, "err".b)
    end

    it "matches bash byte-for-byte on non-UTF-8 output -- the bin payload contract" do
      bash, core = differential("printf '\\377\\000\\376'; printf '\\375' >&2", Lain::WorkerEnv.default)
      expect_identical(bash, core)
      expect(core.content.b).to include("\xFF\x00\xFE".b, "\xFD".b)
    end

    it "matches bash byte-for-byte on a nil-scrubbed-env command: nil removes the key, never empty-string" do
      # Set BEFORE the daemon spawns, so BOTH children inherit it and "absent"
      # can only mean the scrub worked. ${VAR-absent} (no colon) prints
      # "absent" only when UNSET, keeping removal distinguishable from
      # empty-string (the exec.rs contract).
      ENV["LAIN_CORE_EXEC_PROBE"] = "sekrit"
      worker_env = Lain::WorkerEnv.new(cwd: Dir.pwd, env: { "LAIN_CORE_EXEC_PROBE" => nil })
      bash, core = differential("echo \"${LAIN_CORE_EXEC_PROBE-absent}\"", worker_env)
      expect_identical(bash, core)
      expect(core.content).to include("absent\n")
    ensure
      ENV.delete("LAIN_CORE_EXEC_PROBE")
    end

    # Byte-identity is structurally IMPOSSIBLE here (panel ruling, fix 1):
    # mixlib fails INSIDE the forked child -- a ruby backtrace on stderr, exit
    # 1, an ok result carrying that shape -- while the daemon fails AT SPAWN
    # and refuses the call. So the differential pins POSTURE parity instead:
    # both arms hand the model a readable result, and the core arm's error
    # names the cwd that could not be entered.
    it "pins posture parity on a nonexistent cwd: bash's exit-1 shape, core's spawn error naming the cwd" do
      missing = File.join(workdir, "missing")
      bash, core = differential("pwd", Lain::WorkerEnv.new(cwd: workdir, env: {}), cwd: missing)
      expect(bash).to be_ok
      expect(bash.content).to start_with("exit status: 1\n")
      expect(core).to be_error
      expect(core.content).to include("spawn failed", missing)
    end

    # Posture parity again (panel ruling, fix 2): the kill-time partial
    # capture rides the daemon's reply, and mixlib embeds its own in the
    # CommandTimeout message -- structurally different sources, so the pin is
    # that NEITHER arm discards what the command said before the kill.
    it "carries pre-timeout partial output in both arms' timeout error" do
      bash, core = differential("echo before; echo eb >&2; sleep 5", Lain::WorkerEnv.default, timeout: 1)
      expect(bash).to be_error
      expect(core).to be_error
      expect(bash.content.b).to include("before".b, "eb".b)
      expect(core.content.b).to include("before".b, "eb".b)
    end

    it "reports a server-side kill as a timeout error result, mirroring bash's posture" do
      with_client do |client|
        tool = described_class.new(client:)
        result = tool.call({ command: "sleep 5", timeout: 1 }, invocation(Lain::WorkerEnv.default))
        expect(result).to be_error
        expect(result.content).to include("timed out after 1s")
      end
    end

    it "turns boundary death into a Tool::Result.error naming Core::Died -- no hang, no raise" do
      Sync do
        client = Lain::Core::Client.start(paths:)
        tool = described_class.new(client:)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        in_flight = Async { tool.call({ command: "sleep 5" }, invocation(Lain::WorkerEnv.default)) }
        Process.kill("KILL", client.pid)
        result = in_flight.wait
        expect(result).to be_error
        expect(result.content).to include("Lain::Core::Died")
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2.0
      ensure
        client.stop
      end
    end
  end
end
