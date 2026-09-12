# frozen_string_literal: true

module Lain
  module CLI
    class Repl
      # One, or up to four under --auto-approve, --nvim and --secret-oracle,
      # watch the SAME parked-approval queue, and FIRST ANSWER WINS (Pending's
      # own doctrine).
      #
      # The two LLM surfaces are DISJOINT rather than a second opinion on one
      # pending: {Approval::AutoSurface} takes only pendings carrying no
      # sensitive regions and {Approval::SecretSurface} only pendings carrying
      # some, each by a structural filter of its own.
      #
      # Every one of them can be absent, the queue included: under
      # --non-interactive nobody is there to drain a parked call, so `watch`
      # honestly spawns nothing at all.
      class ApprovalSurfaces
        # The two oracle keywords are REQUIRED though they are nil-by-default
        # capabilities: a defaulted keyword turns "the caller forgot to wire it"
        # into a surface that is silently inert. Forgetting one is an
        # ArgumentError.
        def initialize(approvals:, auto_surface:, secret_surface:, tty:, conductor:)
          @approvals = approvals
          @auto_surface = auto_surface
          @secret_surface = secret_surface
          @tty = tty
          @conductor = conductor
        end

        # Bound rather than injected because {Repl} builds this collaborator in
        # its constructor and the frontend only exists once {Repl#run} has
        # attached one. nil is the honest value for a headless chat: there is
        # nothing to construct, so there is nothing left unwired.
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
        # unanswered. read_reply parks the fiber instead.
        def approval_surface
          @approval_surface ||= Lain::Frontend::ApprovalPolicy.new(
            reader: ->(prompt) { @conductor.read_reply(@tty, prompt) }
          )
        end

        # The terminal keyword is false for a line that reads the terminal
        # ITSELF, and then {#approval_surface} -- the ONE surface here that
        # reads stdin, through the same `conductor.read_reply(tty, ...)` a
        # `/inbox` drain would be parked on -- is not spawned.
        # {Repl::LineScope#serve} holds the rule and what withholding it costs.
        #
        # It is also the only surface that CONSUMES the queue's arrivals, so
        # such a line leaves that buffer undrained for its duration -- harmless,
        # because every other surface reads the parked set and never needed an
        # arrival to find a pending.
        #
        # `if terminal` rather than `terminal &&`: `[*false]` is `[false]` where
        # `[*nil]` is empty, and this one splat reads a Boolean where the others
        # read a nil-or-object ivar.
        #
        # Those splats rest on a NEGATIVE fact about a third-party class:
        # `Async::Task` does not respond to `to_a`, so `*task` yields the task
        # itself rather than flattening it. An async release that added `to_a`
        # would silently change what this returns, which is why
        # approval_surfaces_spec pins both the SIZE of this set and the class of
        # every member -- so that upgrade fails in a test rather than in a
        # session's shutdown path.
        def watch(task, terminal: true)
          @approvals && [*(task.async { approval_surface.watch(@approvals) } if terminal),
                         *(@auto_surface && task.async { @auto_surface.watch(@approvals) }),
                         *(@secret_surface && task.async { @secret_surface.watch(@approvals) }),
                         *(@editor && task.async { @editor.watch(@approvals) })]
        end
      end
    end
  end
end
