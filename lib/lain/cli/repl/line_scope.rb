# frozen_string_literal: true

module Lain
  module CLI
    class Repl
      # What ONE DISPATCHED LINE holds open -- {ConversationScope}'s question
      # one lifetime down: which scope owns this fiber, and who stops it.
      #
      # The {HumanReplies} TTY reply loop and the approval watchers
      # ({ApprovalSurfaces}) both answer a human at THIS terminal, and both must
      # run for the whole line: a question or a parked tier-3 call can be raised
      # from any frame the line reaches, and a `@role[/skill]` line's subagent
      # or a registered `/word` never reaches {Repl#respond} at all -- so a
      # surface started inside the ask is not running when it is needed.
      #
      # THE LINE IS THE WIDEST THIS MAY GO. The reply read parks on the stdin
      # the next `you>` prompt needs back, so these fibers must be dead before
      # it is read again; a conversation-scoped answer_loop would sit on the
      # terminal racing every prompt. The editor's gesture rail is scoped to the
      # conversation precisely because it polls a socket and touches no
      # terminal. A block rather than {ConversationScope}'s `open`/`close` pair
      # for the same reason: a line begins and ends inside one call, so the
      # scope owns its own ensure and a caller cannot forget it.
      class LineScope
        # @param replies [HumanReplies] the ask_human reply surfaces for one line
        # @param surfaces [ApprovalSurfaces] the watchers over the parked-approval
        #   queue; spawns nothing under --non-interactive, where there is no queue
        def initialize(replies:, surfaces:)
          @replies = replies
          @surfaces = surfaces
        end

        # The `.stop`s are load-bearing: a parked fiber holds the Sync that owns
        # it open forever.
        #
        # `live` is built EMPTY and filled a half at a time, and that is not
        # style: as one array literal spanning both calls, a raise from the
        # second left the first's fibers unassigned, so the ensure stopped
        # nothing and a reply fiber parked on the terminal outlived its line --
        # which presents as a hung conversation rather than as the error that
        # caused it.
        #
        # == A LINE THAT OWNS THE TERMINAL READ GETS NO TERMINAL SURFACE
        #
        # That is what the owns_terminal keyword enforces, and it is a claim
        # about the one stdin, not about any queue. TWO surfaces here read it --
        # the reply loop's `human> ` and the approval prompt's `[y/N]`, both
        # through `conductor.read_reply(tty, ...)` -- and a line can be a reader
        # in its own right (`/inbox`). Two readers is not a cosmetic race: the
        # keystroke goes to whichever fiber won it, so a line typed at an inbox
        # question can land as the y/N on a gated `bash`, and an inbox answer
        # reaches a `Pending#oldest` that is by then the loop's own item.
        #
        # THE RULE ABOVE IS NARROWER than "at most one fiber holds the terminal
        # read", and is only what this method enforces: on an ORDINARY line both
        # surfaces spawn, so a question and a gated call arriving together put
        # two reads on one stdin with no `/inbox` in sight. Closing that needs
        # the two surfaces to arbitrate for the read, a design call and not a
        # guard -- do not read the heading as claiming it has been made.
        #
        # The withholding costs little, and in the safe direction: every
        # non-terminal surface still watches, the reply queue keeps its items,
        # and a parked call is bounded by {Approval::Queue}'s fail-closed timer.
        # Worst case a call is REFUSED; the alternative's worst case is a call
        # GRANTED by a keystroke meant for something else.
        #
        # @param owns_terminal [Boolean] whether the line reads the terminal
        #   itself
        # @return [Object] whatever the block returned -- a Repl action, or nil
        def serve(owns_terminal: false)
          Sync do |task|
            live = []
            live.push(*@replies.surfaces(task)) unless owns_terminal
            # `*nil` adds nothing, which is the --non-interactive shape: no queue was wired,
            # so `watch` answers nil rather than an empty set.
            live.push(*@surfaces.watch(task, terminal: !owns_terminal))
            yield
          ensure
            live.each { |surface| surface&.stop }
          end
        end
      end
    end
  end
end
