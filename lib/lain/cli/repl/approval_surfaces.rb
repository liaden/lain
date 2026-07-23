# frozen_string_literal: true

module Lain
  module CLI
    class Repl
      # The approval-watching surfaces, lifted out of {Repl} because "which
      # surfaces watch the parked queue, and spawning their fibers" is its own
      # responsibility. Two (or three, under --auto-approve) watch the SAME
      # queue -- the TTY prompt, the desktop notifier, and the opt-in auto
      # surface -- and first answer wins (Pending's own doctrine).
      #
      # `watch(task)` spawns one fiber per live surface and hands the set back
      # for {Repl#respond}'s ensure to stop. The queue is nil under --yolo (no
      # queue was wired), so `watch` spawns NOTHING at all; the notifier is Null
      # with no dunstify, and `auto_surface` is nil without --auto-approve, so
      # the splat adds nothing and the human surfaces are unchanged.
      class ApprovalSurfaces
        def initialize(approvals:, notifier:, auto_surface:, tty:, conductor:)
          @approvals = approvals
          @notifier = notifier
          @auto_surface = auto_surface
          @tty = tty
          @conductor = conductor
        end

        # WHY the reader routes through the conductor: a bare `@input.gets` in
        # the surface fiber races the answer_loop's Reline read for the one
        # stdin, escapes the conductor's countdown-ticker suppression, and --
        # being a thread-blocking read -- freezes the whole reactor, so the
        # queue's fail-closed timer could never fire while the prompt sat
        # unanswered. read_reply parks the fiber instead. Memoized lazily so a
        # --yolo session (no queue, no watch) never builds one.
        def approval_surface
          @approval_surface ||= Lain::Frontend::ApprovalPolicy.new(
            reader: ->(prompt) { @conductor.read_reply(@tty, prompt) }
          )
        end

        # Spawn a watcher fiber per live surface over the one queue; nil under
        # --yolo, so no fiber spawns at all.
        def watch(task)
          @approvals && [task.async { approval_surface.watch(@approvals) },
                         task.async { @notifier.watch(@approvals) },
                         *(@auto_surface && task.async { @auto_surface.watch(@approvals) })]
        end
      end
    end
  end
end
