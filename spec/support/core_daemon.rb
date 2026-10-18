# frozen_string_literal: true

require "fileutils"
require "socket"
require "tmpdir"

# Spawns the built lain-core on a Unix socket for one example and hands the
# connected socket to Core::Client, so the :core example runs the real wire
# with no double between client and daemon. It is the transport: #start
# spawns and connects, #stop reaps.
class CoreDaemon
  BINARY = File.join(Lain::Paths::Shipped.cargo_target, "debug", "lain-core")
  CONNECT_BUDGET = 2.0

  def initialize(binary: BINARY)
    @binary = binary
    @reaping = Mutex.new
    @dir = Dir.mktmpdir("core-daemon")
  end

  def start
    @pid = ::Process.spawn(@binary, File.join(@dir, "core.sock"), File.join(@dir, "core.log"),
                           in: :close, out: :close, err: :close)
    connect
  rescue StandardError
    stop
    raise
  end

  # Idempotent, and serialized because the wait parks the fiber: Core::Client
  # releases its transport on both stop and perish.
  # @return [Process::Status]
  def stop
    @reaping.synchronize { @status ||= reap }
  ensure
    FileUtils.remove_entry(@dir, true)
  end

  private

  def reap
    return unless @pid

    ::Process.kill("TERM", @pid)
    ::Process.wait2(@pid).last
  end

  def connect
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + CONNECT_BUDGET
    begin
      UNIXSocket.new(File.join(@dir, "core.sock"))
    rescue Errno::ENOENT, Errno::ECONNREFUSED
      raise if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
      retry
    end
  end
end
