# frozen_string_literal: true

# The exec boundary's differential cases, once, for every transport that can
# carry them. `Tools::CoreExec` runs the SAME `sh -c` shape as `Tools::Bash` but
# out of process, and the claim under test is that the two are indistinguishable
# in their `Tool::Result` content whichever wire the daemon is reached over.
#
# These cases were duplicated verbatim between the :core (Unix socket, spawned
# daemon) and :vsock (AF_VSOCK, attached daemon) blocks of
# spec/lain/tools/core_exec_spec.rb, whose own notes called them "deliberately
# identical". Deliberate identity is what a shared group states MECHANICALLY --
# two copies can only stay identical by convention, and a fix applied to one is
# a fix missing from the other.
#
# The host block supplies, and is the ONLY thing that differs:
#
#   #with_client              yields a started Lain::Core::Client (and possibly
#                             more -- see Differential#differential). Duplicated
#                             per block on purpose: a shared one would have to
#                             know both transports.
#   let(:workdir)             a tmpdir the cwd cases run in.
#   CoreExecSpecSupport::Differential  included for #differential/#expect_identical.
#
# Transport-SPECIFIC cases stay in their own block: boundary death differs in
# how the daemon is killed and what the error names, and the vsock block's
# #expect_attached_to is what proves that block is not silently running over a
# Unix socket. Nothing here can establish either.
#
# ⚠️ #expect_identical carries no teeth of its own -- see the measurement note
# on CoreExecSpecSupport::Differential. Each case below also asserts its bytes
# LITERALLY, and those literals are what pin the wire.
RSpec.shared_examples "an exec boundary matching bash" do
  it "matches bash byte-for-byte on a text command, cwd threaded through the WorkerEnv" do
    worker_env = Lain::WorkerEnv.new(cwd: workdir, env: {})
    bash, core = differential("pwd -P; echo err >&2; exit 3", worker_env)
    expect_identical(bash, core)
    expect(core.content).to start_with("exit status: 3\n")
    expect(core.content.b).to include(File.realpath(workdir).b, "err".b)
  end

  # The ONE case here that is metacharacter-free, and therefore the only one
  # that exercises what T17 built: Shell::Verdict allows it, so the bash arm
  # runs reconstructed argv through Open3 while core still runs `sh -c`. Every
  # other case in this group contains `;`, a quote or `${}` and so abstains,
  # which compares `sh -c` against `sh -c` exactly as before the term arm
  # existed. The literal is what pins it -- printf writes no trailing newline,
  # so a byte of drift in either arm's rendering shows up here.
  it "matches bash byte-for-byte on a literal command, which bash runs as a TERM" do
    bash, core = differential("printf hi", Lain::WorkerEnv.default)
    expect_identical(bash, core)
    expect(core.content).to eq("exit status: 0\n--- stdout ---\nhi--- stderr ---\n")
  end

  # `sh` is dash, whose printf implements POSIX \ooo but NOT bash's \xNN -- with
  # hex it emits the escape text verbatim on BOTH arms, which reads exactly like
  # a transport corrupting bytes while proving nothing. The octal here is what
  # makes this a real binary-payload assertion.
  it "matches bash byte-for-byte on non-UTF-8 output -- the bin payload contract" do
    bash, core = differential("printf '\\377\\000\\376'; printf '\\375' >&2", Lain::WorkerEnv.default)
    expect_identical(bash, core)
    expect(core.content.b).to include("\xFF\x00\xFE".b, "\xFD".b)
  end

  # T5's output ceiling, and the one case that pins it across a REAL wire.
  # Tools::Bash::OUTPUT_BOUND is applied inside Bash.render_output, which is
  # the single rendering both arms go through -- but "both arms share a method"
  # is a claim about lib/, and only a differential over a live daemon shows the
  # refusal itself surviving the transport. The stdout and stderr halves are
  # each UNDER the ceiling and over it together, so this also pins that the two
  # streams are weighed as one result rather than one each.
  it "matches bash byte-for-byte when the output is refused for size" do
    ceiling = Lain::Tools::Bash::OUTPUT_BOUND.limit
    half = (ceiling / 2) + 1024
    bash, core = differential(
      "head -c #{half} /dev/zero | tr '\\0' x; head -c #{half} /dev/zero | tr '\\0' y >&2; exit 3",
      Lain::WorkerEnv.default
    )
    expect_identical(bash, core)
    expect(core).to have_attributes(is_error: true)
    expect(core.content).to start_with("the command's output (exit status: 3) is #{half * 2} bytes, " \
                                       "over the ceiling of #{ceiling} -- instead, ")
    expect(core.content.b).not_to include("xxxx".b, "yyyy".b)
  end

  it "matches bash byte-for-byte on a nil-scrubbed-env command: nil removes the key, never empty-string" do
    # Set BEFORE the daemon spawns -- and every #with_client spawns or attaches
    # inside #differential, so this ordering holds for each of them. Both
    # children then inherit it, and "absent" can only mean the scrub worked.
    # ${VAR-absent} (no colon) prints "absent" only when UNSET, keeping removal
    # distinguishable from empty-string (the exec.rs contract).
    ENV["LAIN_CORE_EXEC_PROBE"] = "sekrit"
    worker_env = Lain::WorkerEnv.new(cwd: Dir.pwd, env: { "LAIN_CORE_EXEC_PROBE" => nil })
    bash, core = differential("echo \"${LAIN_CORE_EXEC_PROBE-absent}\"", worker_env)
    expect_identical(bash, core)
    expect(core.content).to include("absent\n")
  ensure
    ENV.delete("LAIN_CORE_EXEC_PROBE")
  end

  # Byte-identity is structurally IMPOSSIBLE here (panel ruling, fix 1): mixlib
  # fails INSIDE the forked child -- a ruby backtrace on stderr, exit 1, an ok
  # result carrying that shape -- while the daemon fails AT SPAWN and refuses
  # the call. So this pins POSTURE parity instead: both arms hand the model a
  # readable result, and the core arm's error names the cwd it could not enter.
  # A transport swap does not change that.
  it "pins posture parity on a nonexistent cwd: bash's exit-1 shape, core's spawn error naming the cwd" do
    missing = File.join(workdir, "missing")
    bash, core = differential("pwd", Lain::WorkerEnv.new(cwd: workdir, env: {}), cwd: missing)
    expect(bash).to be_ok
    expect(bash.content).to start_with("exit status: 1\n")
    expect(core).to be_error
    expect(core.content).to include("spawn failed", missing)
  end

  # Posture parity again (panel ruling, fix 2): the kill-time partial capture
  # rides the daemon's reply, and mixlib embeds its own in the CommandTimeout
  # message -- structurally different sources, so the pin is that NEITHER arm
  # discards what the command said before the kill.
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
end
