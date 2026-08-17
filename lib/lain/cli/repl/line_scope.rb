# frozen_string_literal: true

module Lain
  module CLI
    class Repl
      # What ONE DISPATCHED LINE holds open -- {ConversationScope}'s question
      # one lifetime down, and named the same way: which scope owns this fiber,
      # and who stops it.
      #
      # Two surface sets live here and they are one fact: the {HumanReplies} TTY
      # reply loop and the approval watchers ({ApprovalSurfaces}). Both answer a
      # human at THIS terminal about work the line is doing, and both have to be
      # running for the whole of it -- because a question or a parked tier-3 call
      # can be raised from any frame the line reaches, not only from the ask. A
      # `@role[/skill]` line folds a whole subagent run into
      # {Middleware::SkillDispatch}'s short circuit and a registered `/word` runs
      # lib-side; neither reaches {Repl#respond}, and the fiber that parks on
      # what they raise is the dispatching one, so a surface started inside the
      # ask is not running when it is needed.
      #
      # THE LINE IS THE WIDEST THIS MAY GO. The reply read parks on the stdin
      # the next `you>` prompt needs back ({HumanReplies#surfaces}), so these
      # fibers must be dead before it is read again -- a conversation-scoped
      # answer_loop would sit on the terminal racing every prompt, which is a
      # second wedge rather than a fix. The editor's gesture rail is scoped to
      # the conversation precisely because it polls a socket and touches no
      # terminal, and that split is deliberate.
      #
      # A block rather than {ConversationScope}'s `open`/`close` pair, and the
      # difference is the lifetime itself: a conversation is opened in one method
      # and closed in another's ensure, while a line begins and ends inside one
      # call -- so the scope can own its own ensure and a caller cannot forget it.
      class LineScope
        # @param replies [HumanReplies] the ask_human reply surfaces for one line
        # @param surfaces [ApprovalSurfaces] the watchers over the parked-approval
        #   queue; spawns nothing under --yolo, where there is no queue
        def initialize(replies:, surfaces:)
          @replies = replies
          @surfaces = surfaces
        end

        # Spawn every live surface, run the line, and stop them on EVERY path
        # out. The `.stop`s are load-bearing: a parked fiber holds the Sync that
        # owns it open forever, which is the same reason {ConversationScope#close}
        # exists.
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
        # That is the rule `owns_terminal:` enforces, and it is a claim about
        # the one stdin rather than about any one queue. TWO surfaces here read
        # it -- the reply loop's `human> ` and the approval prompt's `[y/N]`,
        # both through `conductor.read_reply(tty, ...)` -- and a line can be a
        # reader in its own right: `/inbox` opens a read of its own
        # ({Registry#serves_replies?} is what asks the command, before anything
        # is called). When it does, NEITHER of these is spawned over it.
        #
        # Two readers is not a cosmetic race. The keystroke goes to whichever
        # fiber won it, so a line typed at an inbox question can land as the y/N
        # on a gated `bash` -- an approval the human never gave -- and an inbox
        # answer reaches `Pending#oldest`, which by then is the loop's own item
        # rather than the one they read.
        #
        # ⚠️ THE RULE ABOVE IS NARROWER THAN "at most one fiber holds the
        # terminal read", and deliberately so: it is what this method enforces,
        # not the property the codebase has. On an ORDINARY line both surfaces
        # spawn, so a question and a gated call arriving together put two reads
        # on one stdin with no `/inbox` anywhere near it -- the same keystroke
        # misdirection, by the ask path. That is not a regression (pre-T1
        # {Repl#respond} spawned the identical pair on every ask) and closing it
        # is a card of its own: it needs the two surfaces to arbitrate for the
        # read, which is a design call, not a guard. Do not read the paragraph
        # above as claiming it has been made.
        #
        # What the withholding costs is bounded, and in the safe direction.
        # Every non-terminal surface still watches: the desktop notifier, the
        # editor's approval list, the two oracles, and the reply queue itself,
        # which keeps its items ({AnswerLoop} re-queues an unanswered one). A
        # tier-3 call parked meanwhile stays parked -- it waits for the next
        # line's surface, and if nobody ever answers it, {Approval::Queue}'s
        # fail-closed timer REFUSES it. The worst case is a call denied; the
        # alternative's worst case is a call granted by a keystroke meant for
        # something else.
        #
        # @param owns_terminal [Boolean] whether the line reads the terminal
        #   itself
        # @return [Object] whatever the block returned -- a Repl action, or nil
        def serve(owns_terminal: false)
          Sync do |task|
            live = []
            live.push(*@replies.surfaces(task)) unless owns_terminal
            # `*nil` adds nothing, which is the --yolo shape: no queue was wired,
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
