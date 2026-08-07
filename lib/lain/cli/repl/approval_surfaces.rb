# frozen_string_literal: true

module Lain
  module CLI
    class Repl
      # The approval-watching surfaces, lifted out of {Repl} because "which
      # surfaces watch the parked queue, and spawning their fibers" is its own
      # responsibility. Two (or up to five, under --auto-approve, --nvim and
      # --secret-oracle) watch the SAME queue -- the TTY prompt, the desktop
      # notifier, the opt-in auto surface, the editor's own list, and the opt-in
      # local-model secret triage -- and first answer wins (Pending's own
      # doctrine).
      #
      # The two LLM surfaces are DISJOINT rather than a second opinion on one
      # pending: {Approval::AutoSurface} takes only pendings carrying no
      # sensitive regions and {Approval::SecretSurface} only pendings carrying
      # some, each by a structural filter of its own.
      #
      # `watch(task)` spawns one fiber per live surface and hands the set back
      # for {Repl#respond}'s ensure to stop. The queue is nil under --yolo (no
      # queue was wired), so `watch` spawns NOTHING at all; the notifier is Null
      # with no dunstify, `auto_surface` is nil without --auto-approve,
      # `secret_surface` is nil without --secret-oracle, and the editor's view
      # is nil with no editor attached, so the splats add nothing and the human
      # surfaces are unchanged.
      class ApprovalSurfaces
        # `secret_surface:` is REQUIRED, like `auto_surface:` and for its
        # reason: both are nil-by-default capabilities, and a defaulted keyword
        # turns "the caller forgot to wire it" into a surface that is silently
        # inert -- which is the same shape as the flag that wires nothing this
        # class's own comment warns about. Forgetting it is an ArgumentError.
        def initialize(approvals:, notifier:, auto_surface:, secret_surface:, tty:, conductor:)
          @approvals = approvals
          @notifier = notifier
          @auto_surface = auto_surface
          @secret_surface = secret_surface
          @tty = tty
          @conductor = conductor
        end

        # The editor's approval list (T36), bound rather than injected because
        # {Repl} builds this collaborator in its constructor and the frontend
        # only exists once {Repl#run} has attached one. nil is the honest value
        # for a headless chat and is what keeps the fourth fiber unspawned --
        # the "capability with no reachable construction" failure this chunk
        # kept producing, answered from the other end: there is nothing to
        # construct, so there is nothing to leave unwired.
        #
        # @param view [Frontend::Neovim::ApprovalView, nil]
        # @return [void]
        def bind_editor(view)
          @editor = view
          nil
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
        #
        # The splat rests on a NEGATIVE fact about a third-party class:
        # `Async::Task` does not respond to `to_a`, so `*task` yields the task
        # itself rather than flattening it. An async release that added `to_a`
        # would silently change what this returns -- which is why
        # approval_surfaces_spec pins both the SIZE of this set and the class of
        # every member, so that upgrade fails in a test rather than in a
        # session's shutdown path.
        def watch(task)
          @approvals && [task.async { approval_surface.watch(@approvals) },
                         task.async { @notifier.watch(@approvals) },
                         *(@auto_surface && task.async { @auto_surface.watch(@approvals) }),
                         *(@secret_surface && task.async { @secret_surface.watch(@approvals) }),
                         *(@editor && task.async { @editor.watch(@approvals) })]
        end
      end
    end
  end
end
