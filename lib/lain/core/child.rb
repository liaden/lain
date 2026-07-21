# frozen_string_literal: true

require "fileutils"
require "socket"

module Lain
  module Core
    # Owns the lain-core daemon's LIFECYCLE and nothing about its wire: spawn
    # with socket-path + tracing-path argv, bounded connect retry, reap on
    # stop. Named Child, not Process -- a Core::Process constant would shadow
    # ::Process for this whole namespace.
    class Child
      # The daemon never accepted within the connect budget while still
      # running -- a hung or misbuilt binary. Distinct from {Core::Died} (it
      # exited) and {Paths::Unwritable} (its home could not be made).
      class Unreachable < Error
        def initialize(socket_path)
          super("lain-core never accepted on #{socket_path} within #{CONNECT_BUDGET}s")
        end
      end

      # Where `rake core:build` compiles to (the workspace target dir).
      # Injectable (`binary:`) so a packaged install can point elsewhere.
      BINARY = File.expand_path("../../../target/debug/lain-core", __dir__)

      # Two seconds in 20ms steps: generous for a debug-build daemon binding a
      # fresh socket, bounded so a wedged binary fails in words, not a hang.
      CONNECT_INTERVAL = 0.02
      CONNECT_BUDGET = 2.0

      def initialize(paths:, binary: BINARY)
        @paths = paths
        @binary = binary
        # Reaping is guarded: the client's reader fiber (on EOF) and #stop can
        # both arrive, and `Process.wait2` parks its caller -- the second
        # arrival must wait for the memo, not race into an ECHILD.
        @reaping = Mutex.new
      end

      # @return [Integer, nil] the daemon's pid once {#start} has spawned it
      attr_reader :pid

      # The one socket-path recipe: `<runtime_dir>/core-<project_hash>.sock`,
      # both halves from {Paths} -- path policy never lives in the daemon.
      def socket_path = File.join(@paths.runtime_dir, "core-#{@paths.project_hash}.sock")

      # Tracing lands beside the socket, same stem. The daemon appends here so
      # its diagnostics can never interleave into the parent's NDJSON Journal.
      def tracing_path = File.join(@paths.runtime_dir, "core-#{@paths.project_hash}.log")

      # Spawn the daemon and connect to it, with a bounded retry while it
      # boots. All three stdio streams are `:close`: diagnostics go to
      # {#tracing_path} only, and an inherited stderr could interleave into
      # the Journal (the wound stays closed).
      # @return [UNIXSocket] the connected socket, ownership passed to caller
      def start
        prepare_runtime_dir
        @pid = ::Process.spawn(@binary, socket_path, tracing_path,
                               in: :close, out: :close, err: :close)
        connect
      rescue Unreachable
        stop
        raise
      end

      # TERM is the daemon's orderly path (its runtime unwinds, and
      # kill_on_drop reaps any execs still running), then reap. Safe to call
      # on a child that already died -- the status memo has the last word.
      def stop
        return if @pid.nil?

        term
        reap
      end

      # Collect the exit status exactly once, parking the caller until the
      # child is truly gone. Idempotent: later callers get the memo.
      # @return [Process::Status]
      def reap
        @reaping.synchronize { status }
      end

      private

      def status
        @status ||= ::Process.wait2(@pid).last
      end

      def prepare_runtime_dir
        FileUtils.mkdir_p(@paths.runtime_dir)
        # Reclaims a crashed daemon's stale socket so the fresh bind succeeds
        # -- but this unlink CANNOT tell stale from serving: a LIVE daemon on
        # this path is silently unseated (its established connections survive;
        # the path is stolen), and a second Child booting during the first's
        # connect retry can cross-wire pid and socket
        # (probes/c2/two_children_same_path). The honest fix is
        # probe-connect-then-refuse, which belongs to the pinned-daemon /
        # adoption chunk -- until then the contract is one Child per project
        # path at a time, by caller discipline.
        FileUtils.rm_f(socket_path)
      rescue SystemCallError => e
        raise Paths::Unwritable.new(@paths.runtime_dir, e)
      end

      def term
        ::Process.kill("TERM", @pid)
      rescue Errno::ESRCH
        # Already gone (killed externally, or dead on arrival); reap still
        # collects the status from the memo or the zombie.
      end

      def connect
        deadline = now + CONNECT_BUDGET
        begin
          UNIXSocket.new(socket_path)
        rescue Errno::ENOENT, Errno::ECONNREFUSED
          raise_if_dead_on_arrival
          raise Unreachable, socket_path if now > deadline

          sleep CONNECT_INTERVAL
          retry
        end
      end

      # A daemon that exited before ever accepting (bad argv, unbindable
      # socket) must fail in ITS terms -- {Died} with the real exit status --
      # not as a connect timeout.
      def raise_if_dead_on_arrival
        _, status = ::Process.wait2(@pid, ::Process::WNOHANG)
        return if status.nil?

        @status = status
        raise Died, status
      end

      def now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end
  end
end
