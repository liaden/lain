# frozen_string_literal: true

module Lain
  module Tools
    # The two questions a caller asks about the set an asker is holding: is one
    # outstanding, and -- for a caller that stopped waiting -- let it go.
    #
    # Its own module because {AskHuman::Outstanding} is the object that answers
    # both, and these are the delegations that publish it. They were two
    # one-line methods in the asker's own body until the withdrawal joined
    # them; extracting the pair is what kept that class inside
    # Metrics/ClassLength rather than loosening a cap to fit one more
    # delegation.
    module Holding
      # @return [Boolean] whether a set is awaiting a reply on this asker
      def pending? = @outstanding.pending?

      # A caller that stopped waiting says so, and the set stops being
      # outstanding so this asker can ask again.
      #
      # An asker admits ONE outstanding set at a time, so a caller that gave up
      # -- {Approval::Gate} when its window closes -- has to withdraw, or every
      # later ask on this asker is refused for the rest of its life while a
      # stale inbox line still offers a question whose answer nobody reads.
      # That is the difference between a human pause costing one gate and
      # costing everything after it.
      #
      # The Q :message STAYS in the record: a withdrawn question was genuinely
      # asked, and the append-only store never loses that. What changes is only
      # that nobody is waiting for its answer any more -- the posture
      # {AskHuman#awaited} already takes when a stop is raised at its park.
      #
      # NAMED, never inferred, exactly as {AskHuman#reply} names the set it
      # answers: a stale handle must not release a set asked after it. A set
      # that was already answered is not pending, so withdrawing it does
      # nothing.
      #
      # @param pending [AskHuman::Pending] the set this caller asked for
      # @return [void]
      def withdraw(pending) = @outstanding.abandon(pending)
    end
  end
end
