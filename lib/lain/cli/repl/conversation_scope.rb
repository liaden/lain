# frozen_string_literal: true

module Lain
  module CLI
    class Repl
      # What a CONVERSATION holds open: which scope owns a fiber, and who stops
      # it. Everything here is one fact -- the supervisor's reactor, which must
      # outlive every per-ask Sync so the fleet has a home across asks, and every
      # surface a human answers through: the editor's gesture consumer, the
      # reply surfaces ({HumanReplies#session_surfaces}) and every watcher over
      # the parked-approval queue ({ApprovalSurfaces#watch}).
      #
      # The surfaces live this long because the work that needs them does: a
      # docent child parks a gated read while the chat sits at rest, and a
      # surface that lived only while a line dispatched left that call to the
      # queue's fail-closed clock. Two terminal prompts cannot race for stdin over this
      # longer life, because the input rail publishes them one at a time.
      #
      # Deliberately NOT {Lain::Session}, which is the run's record and what
      # {Repl#run}'s session keyword carries. This is a lifetime, not a record.
      #
      # {#close} owes every one of them a stop on EVERY exit -- a clean quit, a
      # raise climbing out of the ask, an interrupt at the prompt -- because a
      # parked fiber holds the Sync that owns it open forever.
      class ConversationScope
        # Whether anything is waiting on the human: a parked call or a listed
        # question. A cockpit's command reader is open while this says so. One
        # per conversation and handed to BOTH kinds of surface, because the two
        # kinds of waiting are watched by two objects that share nothing else;
        # each says what "outstanding" means for its own. A LEVEL, asked afresh
        # every time, rather than a latch.
        class Attention
          def initialize = @watched = []

          # @yieldreturn [Boolean] whether this surface has something waiting
          def track(&outstanding) = @watched << outstanding

          def outstanding? = @watched.any?(&:call)
        end

        # @param supervisor [#run, #stop] the fleet's reactor
        # @param replies [#session_surfaces, #chat_surfaces] {HumanReplies}
        # @param surfaces [#watch] {ApprovalSurfaces}, whose `watch` answers nil
        #   under --non-interactive, where no queue was wired
        def initialize(supervisor:, replies:, surfaces:)
          @supervisor = supervisor
          @replies = replies
          @approvals = surfaces
          @surfaces = []
        end

        # Filled a half at a time, so a raise from the second half leaves the
        # first's fibers where {#close} can stop them.
        #
        # @param task [Async::Task] the repl's own Sync, never an ask's
        # @return [self]
        def open(task)
          @supervisor.run(task)
          attention = Attention.new
          @surfaces.push(*@replies.session_surfaces(task))
          @surfaces.push(*@replies.chat_surfaces(task, attention:))
          @surfaces.push(*@approvals.watch(task, attention:))
          self
        end

        # The surfaces first, so the fibers that would hold the Sync open are
        # the first thing gone -- and the supervisor's farewell in an `ensure`,
        # so a surface whose stop misbehaves cannot cost the fleet its
        # drain-on-shutdown.
        def close
          @surfaces.each(&:stop)
        ensure
          @surfaces = []
          @supervisor.stop
        end
      end
    end
  end
end
