# frozen_string_literal: true

require "async"
require "fileutils"
require "tmpdir"

# Everything the describe blocks below need that cannot live inside one, kept
# out of any RSpec block for Lint/ConstantDefinitionInBlock: the Fix-4 client
# duck, and the {Differential} oracle the :core and :vsock blocks share.
module CoreExecSpecSupport
  # A client duck that accepts the call and never replies -- the wire shape of
  # a daemon that failed to enforce its own timeout (pre-3b8c047, pipe-holding
  # grandchildren produced exactly this: a 0.5s timeout held for 5.0s).
  class NeverReplies
    def call(_method, _params)
      Async::Task.current.sleep(3600)
    end
  end

  # The differential harness, lifted out of the :core block so the :vsock block
  # runs the same one rather than a copy free to drift from it. Only the SETUP
  # is duplicated per block (each supplies its own #with_client, because one
  # spawns a daemon through the filesystem and the other attaches to one over
  # AF_VSOCK); nothing here knows which transport it is running over, because
  # it depends on the message and not the type.
  #
  # ⚠️ #expect_identical carries NO teeth of its own, and no comment should
  # imply otherwise. Measured twice, independently, 6 runs each: making both
  # its assertions a no-op reddens ZERO examples. Every byte-identity case
  # also asserts its bytes LITERALLY -- start_with("exit status: 3\n"),
  # include("\xFF\x00\xFE".b), include("absent\n") -- and those literals are
  # what actually pin the wire: corrupting the daemon's stdout reddens exactly
  # the three of them, 10 runs of 10. From the other side, swapping the core
  # arm for a second {Bash} is noticed by 1 of 5 differential examples, and
  # that one is a POSTURE-parity case. The comparison is cheap and states the
  # contract in one line, so it stays; it is just not where the proof is.
  # Pre-existing -- both mutations behave identically against the landed :core
  # block, so this is inherited rather than introduced by the extraction.
  module Differential
    def invocation(worker_env)
      Lain::Tool::Invocation.new(context: Lain::Session.new(worker_env:))
    end

    # The same command through both transports under ONE WorkerEnv; the pair
    # of results, bash's first. #with_client may yield more than the client
    # (the vsock block yields its daemon too, so the boundary-death example
    # can kill it); a one-parameter block simply ignores the rest.
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
    include CoreExecSpecSupport::Differential

    let(:runtime_base) { Dir.mktmpdir("lain-core-exec") }
    let(:paths) { Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => runtime_base }) }
    let(:workdir) { Dir.mktmpdir("lain-core-exec-cwd") }

    after do
      FileUtils.rm_rf(runtime_base)
      FileUtils.rm_rf(workdir)
    end

    def with_client
      Sync do
        client = Lain::Core::Client.start(transport: Lain::Core::Child.new(paths:))
        begin
          yield client
        ensure
          client.stop
        end
      end
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
        # The Child is held here, not reached through the client: {Client#pid}
        # is gone now that the transport is injected, and the caller that built
        # the transport is the one that can kill its daemon.
        child = Lain::Core::Child.new(paths:)
        client = Lain::Core::Client.start(transport: child)
        tool = described_class.new(client:)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        in_flight = Async { tool.call({ command: "sleep 5" }, invocation(Lain::WorkerEnv.default)) }
        Process.kill("KILL", child.pid)
        result = in_flight.wait
        expect(result).to be_error
        expect(result.content).to include("Lain::Core::Died")
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2.0
      ensure
        client.stop
      end
    end
  end

  # The chunk's end-to-end proof, and its ONLY one: the differential above, run
  # with the wire swapped for AF_VSOCK. The claims it establishes -- binary-clean
  # payloads, cwd and env threading, server-side timeout, boundary death --
  # previously survived only as prose in
  # references/firecracker-microvm-isolation.md; the spike that produced them
  # does not exist. So nothing here is a re-confirmation.
  #
  # The HARNESS is shared with the :core block (CoreExecSpecSupport::Differential)
  # and the SETUP is duplicated, which is the split the card asked for: a shared
  # #with_client would have to know both transports and would change the :core
  # path to build it. Do not read the sharing as where the proof lives -- the
  # bash-vs-core comparison is redundant given each case's own literal byte
  # assertions, and it is those literals that have teeth over this wire (see
  # CoreExecSpecSupport::Differential, which measures both directions).
  # The two blocks' cases are otherwise deliberately identical, including
  # which ones pin POSTURE parity rather than byte identity -- the nonexistent
  # cwd and the timeout partial capture are structurally impossible to make
  # byte-identical (see the :core block's notes), and a transport swap does not
  # change that.
  #
  # Tagged :vsock and NOTHING else: --tag lifts the exclusion for the tag it
  # names alone, so `:vsock, :core` would stay excluded under `--tag vsock` and
  # the run would pass green having executed nothing (spec/support/tags.rb).
  describe "against the real daemon reached over vsock", :vsock do
    include CoreExecSpecSupport::Differential

    let(:workdir) { Dir.mktmpdir("lain-core-exec-vsock-cwd") }

    after { FileUtils.rm_rf(workdir) }

    # A daemon and a reactor per call, matching the :core block's shape. No
    # runtime dir and no Paths: an attaching transport provisions nothing, and
    # VsockDaemon owns the daemon's tmpdir and its discovery file.
    def with_client(&block)
      VsockDaemon.run { |daemon| Sync { attach(daemon, &block) } }
    end

    # The only place a Vsock transport is built, deliberately. The daemon is
    # yielded alongside the client so the boundary-death example can kill the
    # very daemon the differential ran against.
    #
    # #expect_attached_to sits INSIDE the ensure, not before it: a client that
    # started and then failed its check would otherwise be left with its reader
    # fiber parked on a live socket, and Sync would never return -- a hang where
    # a failure belongs.
    #
    # The #stop here is UNBOUNDED, unlike the boundary-death example's wait, and
    # deliberately so: {Client#collapse} can park forever (a filed Client
    # defect), but only against a far end whose reader close_read does not EOF.
    # Measured by the T6 panel across six hostile teardown states and 30+
    # repetitions, every teardown from this fixture completed in 0.024-0.077s,
    # the frozen-handshake case landing exactly on HANDSHAKE_BUDGET. A bound
    # here would be guarding a state nothing can currently produce; the note is
    # here so the silence reads as a measurement rather than an oversight.
    def attach(daemon)
      client = Lain::Core::Client.start(transport: Lain::Core::Transport::Vsock.new(port: daemon.port))
      expect_attached_to(client, daemon)
      yield client, daemon
    ensure
      client&.stop
    end

    # The fixture verifying itself, because NOTHING else below can: the
    # differential asserts on process output, which is identical whichever
    # socket carried it, so substituting {Core::Child} in #attach above would
    # leave every case green over a Unix socket -- the whole block inert
    # behind a passing run, which is the failure mode this chunk's reviews keep
    # finding. Measured over 10 runs: without this, that substitution reddens 1
    # of the block's 7 examples; with it, all 7.
    #
    # Behavioural, not a type test -- it never asks the transport what it is.
    # The exec'd `sh` reports its PPID, and the only process that can be its
    # parent is the daemon VsockDaemon spawned, which was started as
    # `lain-core vsock:` and therefore binds AF_VSOCK and nothing else. A
    # second daemon on a Unix socket has a different pid and fails here. One
    # extra round trip, ~1ms.
    #
    # ⚠️ What it proves is WHICH DAEMON ANSWERED, not which address family
    # carried the bytes. The two coincide only because {Transport::Vsock#start}
    # can build nothing but an AF_VSOCK socket, so the only way to reach a
    # different family is to reach a different daemon -- which this catches.
    # A RELAY breaks that coincidence: an AF_UNIX client forwarding to this
    # daemon passes here cleanly (the panel built one). Nothing can do that
    # today, but the deferred hypervisor card is precisely a CONNECT/OK relay,
    # and on the day it lands this stops discriminating and needs replacing.
    #
    # The params are hand-built rather than routed through {CoreExec} because
    # the tool cannot ask a question about its own transport. That couples this
    # one line to lain-core's msgpack schema instead of to the tool under test:
    # cwd, env and timeout_ms are all Option in exec.rs today, so omitting them
    # is legal, but a Rust-side field becoming required would redden all seven
    # examples here for a reason that has nothing to do with any of them.
    def expect_attached_to(client, daemon)
      ppid = client.call("exec", [{ "argv" => ["sh", "-c", "echo $PPID"] }]).fetch("stdout")
      expect(Integer(ppid.strip, 10)).to eq(daemon.pid)
    end

    it "matches bash byte-for-byte on a text command, cwd threaded through the WorkerEnv" do
      worker_env = Lain::WorkerEnv.new(cwd: workdir, env: {})
      bash, core = differential("pwd -P; echo err >&2; exit 3", worker_env)
      expect_identical(bash, core)
      expect(core.content).to start_with("exit status: 3\n")
      expect(core.content.b).to include(File.realpath(workdir).b, "err".b)
    end

    # `sh` is dash, whose printf implements POSIX \ooo but NOT bash's \xNN --
    # with hex it emits the escape text verbatim on BOTH arms, which reads
    # exactly like a transport corrupting bytes while proving nothing. The
    # octal here is what makes this a real binary-payload assertion.
    it "matches bash byte-for-byte on non-UTF-8 output -- the bin payload contract" do
      bash, core = differential("printf '\\377\\000\\376'; printf '\\375' >&2", Lain::WorkerEnv.default)
      expect_identical(bash, core)
      expect(core.content.b).to include("\xFF\x00\xFE".b, "\xFD".b)
    end

    it "matches bash byte-for-byte on a nil-scrubbed-env command: nil removes the key, never empty-string" do
      # Set BEFORE the daemon spawns -- and VsockDaemon spawns inside
      # #with_client, i.e. inside #differential, so this ordering is the same
      # one the :core block relies on. ${VAR-absent} (no colon) prints "absent"
      # only when UNSET, keeping removal distinguishable from empty-string.
      ENV["LAIN_CORE_EXEC_PROBE"] = "sekrit"
      worker_env = Lain::WorkerEnv.new(cwd: Dir.pwd, env: { "LAIN_CORE_EXEC_PROBE" => nil })
      bash, core = differential("echo \"${LAIN_CORE_EXEC_PROBE-absent}\"", worker_env)
      expect_identical(bash, core)
      expect(core.content).to include("absent\n")
    ensure
      ENV.delete("LAIN_CORE_EXEC_PROBE")
    end

    it "pins posture parity on a nonexistent cwd: bash's exit-1 shape, core's spawn error naming the cwd" do
      missing = File.join(workdir, "missing")
      bash, core = differential("pwd", Lain::WorkerEnv.new(cwd: workdir, env: {}), cwd: missing)
      expect(bash).to be_ok
      expect(bash.content).to start_with("exit status: 1\n")
      expect(core).to be_error
      expect(core.content).to include("spawn failed", missing)
    end

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

    # The :core arm of this kills through {Child#pid}; there is no equivalent
    # here and none should be invented -- this transport ATTACHES, so the daemon
    # belongs to VsockDaemon and #stop (TERM-then-reap) is how it dies. TERM is
    # enough on purpose: lain-core returns from its tokio::select! on the
    # signal, which drops every in-flight task and closes the connection, so
    # the client EOFs rather than waiting on a reply that will never come.
    #
    # Unlike the :core arm this also pins the ADDRESS in the error, because
    # Died interpolates whatever Transport#stop reports: it is the assertion
    # that makes "over vsock" a fact about this block rather than a claim in
    # its name.
    #
    # in_flight.wait is bounded so that a REGRESSION is red rather than a hang.
    # {Client#collapse}'s wait is unbounded (a known Client defect, filed in
    # the plan's follow-ups: a wedged run ignored SIGTERM and outlived a 45s
    # deadline by 44 minutes), and a boundary-death test is exactly where that
    # would bite pre-commit and CI.
    it "turns boundary death over vsock into a Tool::Result.error naming the far end -- no hang, no raise" do
      with_client do |client, daemon|
        tool = described_class.new(client:)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        in_flight = Async { tool.call({ command: "sleep 5" }, invocation(Lain::WorkerEnv.default)) }
        daemon.stop
        result = Async::Task.current.with_timeout(10) { in_flight.wait }
        expect(result).to be_error
        expect(result.content).to include("Lain::Core::Died", "AF_VSOCK cid 1 port #{daemon.port}")
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2.0
      end
    end
  end
end
