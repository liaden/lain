# frozen_string_literal: true

require "fileutils"
require "socket"
require "tmpdir"

# Spawns lain-core on an AF_VSOCK port for one example's duration, waits for
# it to report readiness, and reclaims it -- so T5 (the vsock Transport spec)
# and T6 (the exec differential over vsock) share one spawn/wait/teardown
# dance instead of each hand-rolling it. Mirrors Lain::Core::Child's shape
# (spawn, bounded readiness retry, TERM-then-reap), but scoped to one example
# rather than one project, and over AF_VSOCK rather than a Unix path.
#
# T4 (a later wave) has not landed the argv scheme or the port-reporting
# mechanism this depends on -- see .handback-T3.md for the full account and
# what T4 must actually deliver. ASSUMED contract, to be reconciled against
# T4's real card:
#
#   `lain-core vsock:<port-or-nothing> <tracing_path>` binds AF_VSOCK on
#   VMADDR_CID_ANY -- an explicit port if given, VMADDR_PORT_ANY (ephemeral)
#   otherwise -- and once bound writes the assigned port, as decimal text,
#   to "#{tracing_path}.port". That file's existence IS the readiness signal.
#
# If T4 reports the port a different way, this file (and only this file)
# needs revising -- nothing in T5 or T6 should have to know the mechanism.
class VsockDaemon
  # The daemon never reported a vsock port within the budget, WHILE STILL
  # RUNNING: a hung or misbuilt binary, or -- before T4 lands -- a binary that
  # does not understand the vsock scheme yet at all. Distinct from {Died} for
  # the same reason Core::Died is distinct from Child::Unreachable: this one
  # names a timeout, not an exit.
  class Unreachable < StandardError
    def initialize(tracing_path, budget)
      super("lain-core never reported a vsock port via #{tracing_path}.port within #{budget}s")
    end
  end

  # The daemon EXITED before ever reporting readiness -- mirrors Core::Died's
  # own reasoning (lib/lain/core.rb) in miniature: with stdio all `:close`,
  # the exit status is the only diagnostic a developer gets, so it must be in
  # the message, not discarded in favour of a generic timeout that never
  # actually elapsed.
  class Died < StandardError
    def initialize(status)
      super("lain-core exited before ever reporting a vsock port: #{status}")
    end
  end

  # 2s in 20ms steps: the same shape as Child::CONNECT_BUDGET/CONNECT_INTERVAL,
  # generous for a debug build, bounded so a wedged or pre-T4 binary fails in
  # words rather than hanging a spec.
  READY_INTERVAL = 0.02
  READY_BUDGET = 2.0

  # Runs a fresh daemon for the duration of the block and guarantees teardown
  # -- INCLUDING when the block raises. Bare start/stop leaves that case to
  # the caller, and the plan's Grounding names the failure mode by name: "a
  # leaked daemon makes T5's 'nothing is listening' scenario pass for the
  # wrong reason." Prefer this; {#start}/{#stop} stay public for a caller with
  # a genuine reason to hold the daemon across more than one block.
  # @return [Object] the block's own return value
  def self.run(**)
    daemon = new(**).start
    yield daemon
  ensure
    daemon&.stop
  end

  # @param binary [String] path to the lain-core binary; injectable so a spec
  #   can point this at a fixture double rather than the real Rust build.
  # @param port [Integer, nil] pin a specific vsock port, or leave nil for the
  #   ephemeral VMADDR_PORT_ANY scheme T4 specifies.
  def initialize(binary: Lain::Core::Child::BINARY, port: nil)
    @binary = binary
    @requested_port = port
    @dir = Dir.mktmpdir("vsock-daemon")
  end

  # @return [Integer, nil] the daemon's pid once {#start} has spawned it
  attr_reader :pid

  # @return [Integer, nil] the port actually bound (nil until {#start} returns
  #   -- distinct from the `port:` requested at construction, which may be nil
  #   itself under the ephemeral scheme)
  attr_reader :port

  # Tracing lands in a throwaway directory -- one per instance, so concurrent
  # examples never collide the way a shared runtime dir would.
  def tracing_path = File.join(@dir, "core.log")

  # Where the daemon reports its bound port -- see the class comment.
  def ready_path = "#{tracing_path}.port"

  # Spawn and block until the daemon reports its bound port.
  # @return [self]
  # @raise [Unreachable]
  # @raise [Died]
  def start
    # Unlink BEFORE the spawn, not after: the daemon clears this file too, but it
    # cannot do so until fork/exec completes, and #wait_for_port's first pass runs
    # inside that window -- measured, the stale file still held the dead daemon's
    # port at t=0 and only turned over by t=10ms. A stale port is undetectable
    # downstream, because connect(2) to a dead vsock port SUCCEEDS on
    # vsock_loopback, so the reader gets a handshake timeout rather than a
    # refusal. Only the spawner can close that window.
    FileUtils.rm_f(ready_path)
    @pid = ::Process.spawn(@binary, scheme, tracing_path, in: :close, out: :close, err: :close)
    @port = wait_for_port
    self
  rescue Unreachable, Died, SystemCallError
    # SystemCallError here is Process.spawn itself failing (ENOENT on a
    # missing binary, EACCES on one that is not executable) -- @pid may never
    # have been set; #stop tolerates that and still reclaims the tmpdir.
    stop
    raise
  end

  # TERM-then-reap, mirroring Child#stop; safe to call on a daemon that never
  # started or already died. Always reclaims the throwaway directory, even
  # when the daemon never came up.
  def stop
    ::Process.kill("TERM", @pid) if @pid
    ::Process.wait2(@pid) if @pid
  rescue Errno::ESRCH, Errno::ECHILD
    # Already gone -- TERM raced the daemon's own exit, or it was already
    # reaped by the dead-on-arrival check in {#wait_for_port}.
  ensure
    FileUtils.remove_entry(@dir, true)
  end

  private

  def scheme = @requested_port.nil? ? "vsock:" : "vsock:#{@requested_port}"

  def wait_for_port
    deadline = now + READY_BUDGET
    begin
      Integer(File.read(ready_path).strip, 10)
    rescue Errno::ENOENT, ArgumentError
      # ENOENT: not written yet -- the normal, expected pre-ready state.
      # ArgumentError: `ready_path` exists but is EMPTY. T4's card requires
      # an atomic write (temp file + rename(2) in the same directory), so a
      # PARTIALLY written file should never be observable at all -- this
      # does not defend against a torn read; it only tolerates a fully
      # written empty file, which would itself be a T4 bug, not a race. It
      # costs nothing to keep, so it stays, but it is not the atomicity fix.
      raise_if_dead_on_arrival
      raise Unreachable.new(tracing_path, READY_BUDGET) if now > deadline

      sleep READY_INTERVAL
      retry
    end
  end

  # A daemon that exited before ever reporting readiness must fail in ITS
  # terms -- {Died} with the real exit status -- not as a timeout that never
  # actually elapsed. Mirrors Child#raise_if_dead_on_arrival exactly, down to
  # the reasoning: with stdio all `:close`, the status is the only
  # diagnostic a developer gets.
  def raise_if_dead_on_arrival
    _, status = ::Process.wait2(@pid, ::Process::WNOHANG)
    raise Died, status unless status.nil?
  end

  def now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
end
