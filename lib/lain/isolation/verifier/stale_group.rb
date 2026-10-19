# frozen_string_literal: true

module Lain
  module Isolation
    module Verifier
      # The verify process group a suite lock holder left running when it died.
      # A verify runs in its own group, so killing its holder does not kill it;
      # each holder therefore adds the group and its leader's start to its lock
      # line ({#mark}), and the next holder hands that line here ({#call})
      # before its own verify starts.
      #
      # A pid can be reused, so a group is stopped only while its leader's
      # start still matches, or while some member carries a verify's TMPDIR. A
      # group outlives its leader while any member lives, and a pgid that names
      # a live group is never given to a new process; a leader that writes dies
      # of the broken pipe once its holder is gone, so the member scan is the
      # common case, not the corner. A start that cannot be read leaves the
      # group running, and the notice says so.
      class StaleGroup
        GRACE = 2
        POLL = 0.05
        LEFT_BY = / verify_pgid=(\d+) start=(\S+)\z/
        TMP_PREFIX = "lain-verify-"
        MARK = %r{\ATMPDIR=.*/#{TMP_PREFIX}[^/]*\z}

        # @param notice [#call] told, in words, what became of a group a dead holder left
        # @param proc_root [String] the process table, read for a leader's start and a group's members
        # @param signal [#call] `Process.kill`; signal 0 delivers nothing
        # @param grace [Numeric] seconds a group is given to end after TERM, and again after KILL
        # @param clock [#call] monotonic seconds, which time the grace
        def initialize(notice: ParentLock::Silent, proc_root: "/proc", signal: Process.public_method(:kill),
                       grace: GRACE, clock: RunClock::MONOTONIC)
          @notice = notice
          @proc_root = proc_root
          @probe = Liveness::Probe.new(proc_root:)
          @signal = signal
          @grace = grace
          @clock = clock
        end

        # @param pgid [Integer] the verify's process group, which is its leader's pid
        # @return [String] the text a holder adds to its lock line
        def mark(pgid) = "verify_pgid=#{pgid} start=#{@probe.start_of(pgid)}"

        # The anchor is the line's end, because the command before it is argv
        # joined unescaped and may hold anything.
        # @param line [String] a dead holder's lock line
        # @return [nil]
        def call(line)
          left = LEFT_BY.match(line) or return
          pgid = Integer(left[1])
          case @probe.of(pgid, started_at: left[2])
          when :live then stop(pgid)
          when :unknown then @notice.call(unread(pgid))
          else stop(pgid) if verify_members?(pgid)
          end
          nil
        end

        private

        def unread(pgid)
          "a dead suite lock holder left verify group #{pgid} and its leader's start time cannot be read, " \
            "so this verify left it running"
        end

        def verify_members?(pgid)
          Dir.children(@proc_root).grep(/\A\d+\z/).any? { |pid| in_group?(pid, pgid) && marked?(pid) }
        rescue SystemCallError
          false
        end

        def in_group?(pid, pgid)
          File.read(File.join(@proc_root, pid, "stat")).rpartition(")").last.split[2] == pgid.to_s
        rescue SystemCallError
          false
        end

        def marked?(pid)
          File.binread(File.join(@proc_root, pid, "environ")).split("\0").any? { |entry| MARK.match?(entry) }
        rescue SystemCallError
          false
        end

        def stop(pgid)
          send_group(pgid, "TERM")
          send_group(pgid, "KILL") unless ended?(pgid)
          @notice.call(ended?(pgid) ? stopped(pgid) : unstoppable(pgid))
        end

        def stopped(pgid) = "stopped verify group #{pgid}, left running by a dead suite lock holder"

        def unstoppable(pgid)
          "verify group #{pgid}, left running by a dead suite lock holder, could not be stopped; " \
            "this verify runs beside it"
        end

        def ended?(pgid)
          deadline = clock + @grace
          sleep(POLL) while group?(pgid) && clock < deadline
          !group?(pgid)
        end

        def group?(pgid)
          @signal.call(0, -pgid)
          true
        rescue Errno::ESRCH
          false
        rescue Errno::EPERM
          true
        end

        def send_group(pgid, name)
          @signal.call(name, -pgid)
        rescue Errno::ESRCH, Errno::EPERM
          nil # already gone, or no longer ours to signal
        end

        def clock = @clock.call
      end
    end
  end
end
