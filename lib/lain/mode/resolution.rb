# frozen_string_literal: true

module Lain
  class Mode
    # The one place a mode becomes the live collaborators a session holds.
    # Pure: it wires nothing, mutates nothing, touches no filesystem, and it
    # raises before anything moves, which is what keeps a refused flip out of
    # the journal.
    #
    # It does not build a ladder. Only the session's board holds the queue, the
    # rules and the triage rung a ladder is made of, so the board builds one per
    # approval level ONCE and hands them in; a flip then selects one. Selecting
    # rather than building is also what makes a flip back to the level in force
    # resolve to the identical policy, so the policy switch can see that nothing
    # moved. Frozen but NOT `Ractor.shareable?`, unlike the rest of the mode
    # family: it holds live collaborators on purpose.
    Resolution = Data.define(:gate_policy)

    class Resolution
      # Loud rather than defaulted: a silently-dropped policy is an approval gate
      # that quietly stops guarding.
      class Unknown < Error; end

      # Takes the whole {Mode} and reads only `approval` today: scope is the
      # other axis a resolution will read, and folding it in then is a change to
      # this method's body rather than to its signature and every caller.
      #
      # @param mode [Lain::Mode] the mode this session is in
      # @param ladders [Hash{Symbol => #rule}] the session's gate policy for each
      #   approval level, keyed by level name
      # @return [Resolution]
      # @raise [Unknown] when no policy stands for the mode's approval level
      def self.for(mode:, ladders:)
        level = mode.approval.name
        policy = ladders.fetch(level, nil)
        raise Unknown, format(MISSING, level:, known: ladders.keys.inspect) if policy.nil?

        new(gate_policy: policy)
      end

      MISSING = "cannot resolve approval %<level>s: the session was wired no gate policy for it " \
                "(it holds %<known>s), and a level with no policy behind it would stop guarding in silence"
      private_constant :MISSING
    end
  end
end
