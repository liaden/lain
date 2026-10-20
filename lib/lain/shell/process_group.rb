# frozen_string_literal: true

module Lain
  module Shell
    # TERM to a whole process group, a poll for it to end, then KILL: the stop
    # {Out} gives a timed-out command and {Isolation::Verifier::StaleGroup}
    # gives a verify a dead lock holder left. The group outlives its leader
    # when a descendant ignores TERM, so the grace is spent until the whole
    # group is gone, and KILL goes to the group even after the leader has been
    # reaped.
    class ProcessGroup
      # What a stranger's group is reaped with: nothing, as it is not our child.
      NULL_REAPER = -> {}

      # @param signal [#call] `Process.kill`; signal 0 delivers nothing
      # @param clock [#call] monotonic seconds, which time the grace
      # @param grace [Numeric] seconds the group is given to end after each signal
      # @param poll [Numeric] seconds between looks at the group
      # @param sleeper [#call] waits the given seconds
      def initialize(clock:, grace:, poll:, signal: Process.public_method(:kill), sleeper: Kernel.method(:sleep))
        @signal = signal
        @clock = clock
        @grace = grace
        @poll = poll
        @sleeper = sleeper
      end

      # @param pgid [Integer] the group, which is its leader's pid
      # @param reaper [#call] collects an exited leader, which a zombie group would otherwise outlive
      # @return [nil]
      def terminate(pgid, reaper: NULL_REAPER)
        send_signal(pgid, "TERM")
        send_signal(pgid, "KILL") unless ended?(pgid, reaper:)
        nil
      end

      # @param pgid [Integer]
      # @param reaper [#call]
      # @return [Boolean] whether the group is gone, once it has had the grace to end
      def ended?(pgid, reaper: NULL_REAPER)
        deadline = @clock.call + @grace
        reaper.call
        while alive?(pgid) && @clock.call < deadline
          @sleeper.call(@poll)
          reaper.call
        end
        !alive?(pgid)
      end

      private

      def alive?(pgid)
        @signal.call(0, -pgid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def send_signal(pgid, name)
        @signal.call(name, -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        nil # already gone, or no longer ours to signal
      end
    end
  end
end
