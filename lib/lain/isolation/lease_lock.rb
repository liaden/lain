# frozen_string_literal: true

require "socket"
require "time"

module Lain
  module Isolation
    # The reason lain writes into `git worktree lock`, read back. The lock is
    # lain's liveness record for a checkout: it is taken by the same
    # `worktree add` that creates the checkout, so no moment exists in which a
    # leased tree is unlocked, and it needs no journal, so a run that records
    # nothing still marks what it holds.
    #
    # Four shapes answer one duck: whether the lock `held?` its worktree
    # against reaping (and `why`), and what the worktree's age counts from.
    # Anything lain cannot parse holds, because a lock nobody can explain is
    # one nobody may break.
    module LeaseLock
      LEASE = /\Alain-lease pid=(\d+) start=(\S+) host=(\S+)\z/
      RETAINED = /\Alain-retained since=(\S+)\z/

      # A start time that could not be read, on a system without `/proc`.
      UNKNOWN_START = "-"

      # Taken by a running process. Whether that process is still the one
      # holding it is the {ProcessTable}'s question, never this value's.
      Held = Data.define(:pid, :start, :host) do
        def initialize(pid:, start:, host:)
          super(pid: Integer(pid), start: -start.to_s, host: -host.to_s)
        end

        def reason = "lain-lease pid=#{pid} start=#{start} host=#{host}"

        def held?(table) = table.verdict(self) != :dead

        def why(table)
          case table.verdict(self)
          when :live then "leased by live process #{pid} on #{host}"
          when :dead then "leased by process #{pid} on #{host}, which has exited"
          else "leased on another host (#{host})"
          end
        end

        def aged_from(created) = created
      end

      # Written by a release that found uncommitted work. Nothing holds the
      # checkout any more, and its age counts from the moment it was retained.
      Retained = Data.define(:stamp) do
        def self.at(time) = new(stamp: time.utc.iso8601)

        def initialize(stamp:)
          super(stamp: -stamp.to_s)
        end

        def since = Time.iso8601(stamp)

        def reason = "lain-retained since=#{stamp}"

        def held?(_table) = false

        def why(_table) = "retained since #{stamp}"

        def aged_from(_created) = since
      end

      Foreign = Data.define(:reason) do
        def initialize(reason:)
          super(reason: -reason.to_s)
        end

        def held?(_table) = true

        def why(_table) = "locked by something lain did not write (#{reason.inspect})"

        def aged_from(created) = created
      end

      # No lock at all: a checkout from before leases were locked, or one whose
      # unlock landed and whose removal did not.
      UNLOCKED = Class.new do
        def held?(_table) = false

        def why(_table) = "not locked"

        def aged_from(created) = created
      end.new.freeze

      # @param reason [String, nil] the lock's reason as git reports it; nil
      #   when git holds no lock, "" for a lock taken with no reason
      def self.parse(reason)
        case reason
        when nil then UNLOCKED
        when LEASE then Held.new(pid: Regexp.last_match(1), start: Regexp.last_match(2), host: Regexp.last_match(3))
        when RETAINED then retained(Regexp.last_match(1), reason)
        else Foreign.new(reason:)
        end
      end

      def self.retained(stamp, reason)
        Retained.at(Time.iso8601(stamp))
      rescue ArgumentError
        Foreign.new(reason:)
      end
      private_class_method :retained

      # Whether the process a lease names is still the one that took it.
      #
      # Conservative in one direction only. A reused pid whose start time
      # cannot be read reads as live, which keeps a crashed checkout a day
      # longer; the other mistake would reap a live worker's tree. A lease from
      # another host is never judged at all, since this host's process table
      # says nothing about that one's.
      class ProcessTable
        # Field 22 of `/proc/<pid>/stat`, counted from after the command name,
        # which may itself hold spaces and parentheses.
        START_FIELD = 19

        # @param pid [Integer] the process {#current} names
        # @param host [String] this host, as leases name it
        # @param proc_root [String] where `<pid>/stat` is read from
        # @param signal [#call] `Process.kill`; signal 0 asks only whether the
        #   pid exists
        def initialize(pid: Process.pid, host: Socket.gethostname, proc_root: "/proc",
                       signal: Process.public_method(:kill))
          @pid = pid
          @host = host
          @proc_root = proc_root
          @signal = signal
        end

        # @return [Held] the lease this process writes into a lock
        def current = Held.new(pid: @pid, start: start_of(@pid), host: @host)

        # @param held [Held]
        # @return [Symbol] :live, :dead, or :elsewhere for another host's lease
        def verdict(held)
          return :elsewhere unless held.host == @host

          exists?(held.pid) && same_start?(held) ? :live : :dead
        end

        private

        # EPERM is a process that exists and belongs to somebody else.
        def exists?(pid)
          @signal.call(0, pid)
          true
        rescue Errno::EPERM
          true
        rescue Errno::ESRCH
          false
        end

        def same_start?(held)
          now = start_of(held.pid)
          [held.start, now].include?(UNKNOWN_START) || held.start == now
        end

        def start_of(pid)
          fields = File.read(File.join(@proc_root, pid.to_s, "stat")).rpartition(")").last.split
          fields.fetch(START_FIELD, UNKNOWN_START)
        rescue SystemCallError
          UNKNOWN_START
        end
      end
    end
  end
end
