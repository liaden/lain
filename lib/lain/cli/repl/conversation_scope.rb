# frozen_string_literal: true

module Lain
  module CLI
    class Repl
      # What a CONVERSATION holds open, as against what one ask does: which
      # scope owns this fiber, and who stops it. Two things live here and they
      # are one fact -- the supervisor's reactor, which must outlive every
      # per-ask Sync so the fleet has a home across asks, and the editor's
      # gesture consumer, whose rail a human uses BETWEEN asks.
      #
      # Deliberately NOT {Lain::Session}, which is the run's record and what
      # {Repl#run}'s session keyword carries. This is a lifetime, not a record.
      #
      # {#close} owes every one of them a stop on EVERY exit -- a clean quit, a
      # raise climbing out of the ask, an interrupt at the prompt -- because a
      # parked fiber holds the Sync that owns it open forever.
      #
      # The counterpart lifetime is one DISPATCHED LINE ({LineScope}), and the
      # reason it is not THIS one is the terminal: the TTY reply read parks on
      # the stdin the next `you>` prompt needs back, so a conversation-scoped
      # answer_loop would race every prompt for it. The editor's rail is scoped
      # here precisely because it polls a socket and touches no terminal.
      class ConversationScope
        def initialize(supervisor:, replies:)
          @supervisor = supervisor
          @replies = replies
        end

        # @param task [Async::Task] the repl's own Sync, never an ask's
        # @return [self]
        def open(task)
          @supervisor.run(task)
          @surfaces = @replies.session_surfaces(task)
          self
        end

        # The surfaces first, so the fibers that would hold the Sync open are
        # the first thing gone -- and the supervisor's farewell in an `ensure`,
        # so a surface whose stop misbehaves cannot cost the fleet its
        # drain-on-shutdown. `@surfaces` is nil when {#open} raised before it
        # got that far, the path a bad reactor takes.
        def close
          @surfaces&.each(&:stop)
        ensure
          @surfaces = nil
          @supervisor.stop
        end
      end
    end
  end
end
