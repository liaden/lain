# frozen_string_literal: true

require "socket"

module Lain
  # Whether the process a record names is still the one that wrote it: the one
  # question a lease lock, a session header and gc all ask of a pid, answered
  # one way.
  #
  # Every such record carries the same identity: a pid, that process's start in
  # clock ticks since boot, and the host. Signal 0 asks only whether the pid
  # exists, and EPERM is a process that exists and belongs to somebody else, so
  # it is not evidence of death. Existence proves nothing once a pid can be
  # reused, so the start must also match exactly: ticks count on the boot
  # clock, which a wall-clock step never moves, and a later boot's process
  # cannot carry the same start. A start that cannot be compared answers
  # `:unknown`, and each caller resolves that in the direction its own mistake
  # is cheapest: a lease holds, a watch keeps tailing, a resume does not claim
  # the session is open.
  #
  # The identity names no pid namespace, so a record written inside a
  # container and judged outside it is judged against the wrong table.
  module Liveness
    # A start time that could not be read, on a system without `/proc`.
    UNKNOWN_START = "-"

    VERDICTS = %i[live dead unknown].freeze

    # @param pid [Integer]
    # @param started_at [String] the start field the record holds for its writer
    # @param probe [Probe]
    # @return [Symbol] one of {VERDICTS}
    def self.of(pid, started_at:, probe: Probe.new) = probe.of(pid, started_at:)

    # The process table, read through `/proc`.
    class Probe
      # Field 22 of `/proc/<pid>/stat`, counted from after the command name,
      # which may itself hold spaces and parentheses.
      START_FIELD = 19

      # @param proc_root [String] where `<pid>/stat` is read from
      # @param signal [#call] `Process.kill`; signal 0 delivers nothing
      def initialize(proc_root: "/proc", signal: Process.public_method(:kill))
        @proc_root = proc_root
        @signal = signal
      end

      # @param pid [Integer]
      # @param started_at [String] the start field the record holds
      # @return [Symbol] one of {VERDICTS}
      def of(pid, started_at:)
        return :dead unless exists?(pid)

        start = start_of(pid)
        return :unknown if [start, started_at].include?(UNKNOWN_START)

        start == started_at ? :live : :dead
      end

      # @param pid [Integer]
      # @return [String] the process's start field, or {UNKNOWN_START}
      def start_of(pid)
        fields = File.read(File.join(@proc_root, pid.to_s, "stat")).rpartition(")").last.split
        fields.fetch(START_FIELD, UNKNOWN_START)
      rescue SystemCallError
        UNKNOWN_START
      end

      private

      # A pid too large for the kernel's type is one no process can hold.
      def exists?(pid)
        @signal.call(0, pid)
        true
      rescue Errno::EPERM
        true
      rescue Errno::ESRCH, RangeError
        false
      end
    end

    Writer = Data.define(:pid, :start, :host)

    # The process writing a session file, recorded in its header so a reader in
    # another process can ask after it.
    class Writer
      HEADER_KEY = "writer"

      # A tick count, or {UNKNOWN_START}: anything else could never match a
      # real start, and would read a live writer as dead.
      START = /\A(?:\d+|#{Regexp.escape(UNKNOWN_START)})\z/

      # A header that records no writer: one written before writers were
      # recorded, or one not written by a chat at all.
      UNRECORDED = Class.new do
        def pid = nil

        def to_header = {}

        def verdict(*) = :unknown
      end.new.freeze

      # @param probe [Probe] reads this process's start
      # @return [Writer] this process
      def self.current(probe: Probe.new)
        new(pid: Process.pid, start: probe.start_of(Process.pid), host: Socket.gethostname)
      end

      # @param header [Hash{String=>Object}] a session header record
      # @return [Writer] {UNRECORDED} when the header names no writer
      def self.from_header(header)
        fields = header[HEADER_KEY]
        return UNRECORDED unless fields.is_a?(Hash) && START.match?(fields["start"].to_s)

        new(pid: fields.fetch("pid"), start: fields.fetch("start"), host: fields.fetch("host"))
      rescue KeyError, ArgumentError, TypeError
        UNRECORDED
      end

      def initialize(pid:, start:, host:)
        super(pid: Integer(pid), start: -start.to_s, host: -host.to_s)
      end

      # @return [Hash{String=>Hash}] the header field naming this writer
      def to_header = { HEADER_KEY => { "pid" => pid, "start" => start, "host" => host } }

      # @param probe [Probe]
      # @param host [String] this host; another host's process table is not this one
      # @return [Symbol] one of {VERDICTS}
      def verdict(probe = Probe.new, host: Socket.gethostname)
        self.host == host ? Liveness.of(pid, started_at: start, probe:) : :unknown
      end
    end
  end
end
