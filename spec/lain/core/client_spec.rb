# frozen_string_literal: true

require "async"
require "fileutils"
require "tempfile"

RSpec.describe Lain::Core::Client, :core do
  # Every example drives a REAL lain-core daemon whose socket and tracing file
  # live under a throwaway XDG runtime dir injected through Paths -- nothing
  # touches the machine's real /run/user or /tmp/lain, and parallel workers
  # cannot collide.
  let(:runtime_base) { Dir.mktmpdir("lain-core-client") }
  let(:paths) { Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => runtime_base }) }

  after { FileUtils.rm_rf(runtime_base) }

  def with_client(**options)
    Sync do
      client = Lain::Core::Client.start(paths:, **options)
      begin
        yield client
      ensure
        client.stop
      end
    end
  end

  def exec_params(*argv)
    [{ "argv" => argv }]
  end

  def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # A misbehaving stand-in daemon: binds the socket-path argv like the real
  # binary, then runs `body`. Generated into the per-example tempdir --
  # `binary:` is an injected seam, so no committed fixture scripts are needed.
  def fake_daemon(name, body)
    path = File.join(runtime_base, name)
    File.write(path, <<~SCRIPT)
      #!#{RbConfig.ruby}
      require "socket"
      server = UNIXServer.new(ARGV.fetch(0))
      #{body}
    SCRIPT
    File.chmod(0o755, path)
    path
  end

  it "demuxes concurrent calls by msgid, bounded by the longer call not the sum" do
    with_client do |client|
      fast_elapsed = nil
      started = monotonic_now
      slow = Async { client.call("exec", exec_params("sh", "-c", "sleep 0.3; echo slow")) }
      fast = Async do
        client.call("exec", exec_params("sh", "-c", "echo fast")).tap { fast_elapsed = monotonic_now - started }
      end
      expect(slow.wait.fetch("stdout")).to eq("slow\n")
      expect(fast.wait.fetch("stdout")).to eq("fast\n")
      # The daemon answers the fast call FIRST (C1's out-of-order contract), so
      # only msgid demux can hand each fiber its own result. A client that
      # serialized calls would hold the fast answer hostage behind the slow one.
      expect(fast_elapsed).to be < 0.2
      expect(monotonic_now - started).to be < 0.55
    end
  end

  it "fails in-flight and subsequent calls with Core::Died naming the signal" do
    with_client do |client|
      in_flight = Async do
        # The expectation lives INSIDE the task so the raise is consumed here,
        # not re-raised (with a console warning) out of task.wait.
        expect { client.call("exec", exec_params("sleep", "5")) }
          .to raise_error(Lain::Core::Died, /SIGKILL|signal 9/)
      end
      Process.kill("KILL", client.pid)
      in_flight.wait
      expect { client.call("ping") }.to raise_error(Lain::Core::Died, /SIGKILL|signal 9/)
    end
  end

  it "puts the socket and tracing file under the runtime dir and nothing on the parent's stderr" do
    captured = capturing_parent_stderr do
      with_client do |client|
        expect(File.socket?(File.join(runtime_base, "lain", "core-#{paths.project_hash}.sock"))).to be(true)
        expect(File.file?(File.join(runtime_base, "lain", "core-#{paths.project_hash}.log"))).to be(true)
        client.call("ping")
      end
    end
    expect(captured).to eq("")
  end

  it "surfaces a server error reply as Refused, verbatim, without hurting the connection" do
    with_client do |client|
      expect { client.call("no_such_method") }
        .to raise_error(Lain::Core::Client::Refused, /no_such_method/)
      expect(client.call("ping").fetch("version")).to eq(Lain::Core::Client::PROTOCOL_VERSION)
    end
  end

  # Promoted from probes/c2/misbehaving_daemons.rb case 1: pre-fix, the
  # malformed frame killed the reader silently -- the in-flight caller parked
  # forever AND Async's console logger dumped the unhandled task failure as
  # JSON onto stderr (the Journal-interleave hazard the AST spec cannot see,
  # because async writes it, not lain).
  it "fails loudly on undecodable frames instead of parking callers or leaking to stderr" do
    garbage = fake_daemon("garbage-daemon", <<~BODY)
      conn = server.accept
      conn.write([0xC1].pack("C") + "garbage")
      conn.flush
      sleep 60
    BODY
    captured = capturing_parent_stderr do
      Sync do
        expect { Lain::Core::Client.start(paths:, binary: garbage) }
          .to raise_error(Lain::Core::Died, /SIGTERM|signal 15/)
      end
    end
    expect(captured).to eq("")
  end

  # Promoted from probes/c2/misbehaving_daemons.rb case 3: pre-fix, perish
  # assumed the child was already dead and parked forever in Process.wait2
  # against a daemon that dropped the socket while staying alive.
  it "forces the exit it reports: a close-but-alive daemon is TERMed, never waited on" do
    close_alive = fake_daemon("close-alive-daemon", <<~BODY)
      server.accept.close
      sleep 60
    BODY
    Sync do
      expect { Lain::Core::Client.start(paths:, binary: close_alive) }
        .to raise_error(Lain::Core::Died, /SIGTERM|signal 15/)
    end
  end

  # Promoted from probes/c2/misbehaving_daemons.rb case 2: the connect budget
  # is bounded, and the handshake must be too -- accept-then-silence would
  # otherwise park Client.start forever.
  it "bounds the handshake: a daemon that accepts but never answers fails in the budget's words" do
    mute = fake_daemon("mute-daemon", <<~BODY)
      server.accept
      sleep 60
    BODY
    Sync do
      started = monotonic_now
      expect { Lain::Core::Client.start(paths:, binary: mute, handshake_budget: 0.3) }
        .to raise_error(Lain::Core::Client::HandshakeTimeout, /0\.3/)
      expect(monotonic_now - started).to be < 2.0
    end
  end

  it "distinguishes a voluntary stop: calls after #stop raise Stopped, not Died" do
    with_client do |client|
      client.call("ping")
      client.stop
      expect { client.call("ping") }.to raise_error(Lain::Core::Client::Stopped, /stopped/)
    end
  end

  it "refuses a daemon whose protocol version differs, naming both versions" do
    Sync do
      # The raise must also have stopped the child and its reader fiber, or
      # this Sync block would hang on the orphaned reader -- the example
      # finishing at all is the cleanup assertion.
      expect { Lain::Core::Client.start(paths:, version: "999.0.0") }
        .to raise_error(Lain::Core::Client::VersionMismatch) do |error|
          expect(error.message).to include("999.0.0", Lain::Core::Client::PROTOCOL_VERSION)
        end
    end
  end

  private

  # Redirect the process-level fd 2 -- what a spawned child would inherit --
  # into a tempfile for the duration. Reassigning $stderr to a StringIO would
  # only catch Ruby-side writes; fd inheritance is what the daemon's
  # `err: :close` contract is about.
  def capturing_parent_stderr
    absorb_experimental_io_buffer_warning
    capture = Tempfile.new("lain-core-stderr")
    backup = $stderr.dup
    $stderr.reopen(capture.path, "w")
    yield
    $stderr.flush
    File.read(capture.path)
  ensure
    restore_stderr(backup, capture)
  end

  def restore_stderr(backup, capture)
    $stderr.reopen(backup)
    backup.close
    capture.close!
  end

  # Ruby's once-per-process "IO::Buffer is experimental" warning fires on the
  # FIRST scheduler-hooked read anywhere in the process (async's io_read hook
  # uses IO::Buffer). Trigger it deterministically before capturing, so the
  # capture holds what the daemon and client wrote -- the contract under
  # test -- and not Ruby's own environmental notice, which would otherwise
  # land in whichever example happens to read first under random ordering.
  def absorb_experimental_io_buffer_warning
    IO::Buffer.new(1)
  end
end
