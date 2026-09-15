# frozen_string_literal: true

module Lain
  module CLI
    class Repl
      # Up to four watch the SAME parked-approval queue, and FIRST ANSWER WINS
      # (Pending's own doctrine): the terminal's surface, the automatic approver
      # every attended session is built with, the editor's under --nvim, and the
      # secret oracle under --secret-oracle. The automatic approver's fiber
      # always runs and decides only while the `auto_approve` mode layer is on,
      # so turning the layer on or off mid-session needs no watcher respawned.
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
        # ITSELF, and then the terminal's own surface is not spawned.
        # {Repl::LineScope#serve} holds the rule and what withholding it costs.
        #
        # WHICH terminal surface depends on the editor. A plain chat gets
        # {#approval_surface}, the ONE surface here that reads stdin, through the
        # same `conductor.read_reply(tty, ...)` a `/inbox` drain would be parked
        # on. A cockpit gets {Arrivals}, which reads nothing: lain://approval is
        # where the human answers there, and a `[y/N]` in the chat pane beside it
        # is a second reader for a line typed ahead to land in.
        #
        # {#approval_surface} is also the only surface that CONSUMES the queue's
        # arrivals, so a line without it leaves that buffer undrained --
        # harmless, because every other surface reads the parked set and never
        # needed an arrival to find a pending, and {Approval::Queue#dequeue}
        # skips the decided ones a later reader would otherwise meet.
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
        #
        # @param task [Async::Task] the line's task, which every watcher is spawned on
        # @param terminal [Boolean] false for a line that reads the terminal itself
        # @param attention [LineScope::Attention] told, in a cockpit, that an
        #   undecided parked call is outstanding, so the chat's command reader
        #   is open while one is
        def watch(task, terminal: true, attention: LineScope::Attention.new)
          @approvals && [*(terminal_surface(task, attention) if terminal),
                         *(@auto_surface && task.async { @auto_surface.watch(@approvals) }),
                         *(@secret_surface && task.async { @secret_surface.watch(@approvals) }),
                         *(@editor && task.async { @editor.watch(@approvals) })]
        end

        private

        # In a cockpit the parked set is outstanding whichever line parked it:
        # a line blocked on a call announced earlier still needs `/approve`.
        def terminal_surface(task, attention)
          return task.async { approval_surface.watch(@approvals) } unless @editor

          attention.track { @approvals.any? { |pending| !pending.decided? } }
          task.async { arrivals.watch(@approvals) }
        end

        # Memoized for {Arrivals}' reason: it remembers what it has announced,
        # and that memory spans every line a call stays parked through.
        def arrivals = @arrivals ||= Arrivals.new(notice: @tty.method(:render_warning))
      end

      class ApprovalSurfaces
        # A parked call announced in a cockpit's chat pane as ONE line naming
        # where it is answered, and nothing read.
        #
        # It OBSERVES the parked set rather than draining the arrival queue,
        # because {Frontend::ApprovalPolicy} is the one consumer that queue may
        # have (`spec/approval_consumer_discipline_spec.rb`), and it POLLS for the
        # reason {Frontend::Neovim::ApprovalView} does: a sibling fiber on the
        # reactor, woken by its own tick, needs nothing from the queue to find a
        # pending.
        #
        # A call is announced ONCE however many lines it outlives, and forgotten
        # the moment it leaves the parked set, so the memory is bounded by what
        # is parked right now.
        #
        # `notice:` is the frontend's one-line note ({Frontend::TTY#render_warning},
        # reached as {CLI::Wiring} reaches it for the run's line to the human).
        class Arrivals
          TICK = 0.05

          # The requester is a wired name, never model text. The CALL is
          # `inspect`ed, so a newline or an escape in a model-written command
          # cannot break the line or forge another; the preamble is the
          # sentence every human surface leads with. The buffer is a format
          # argument rather than interpolated here because `lain/frontend`
          # loads after `lain/cli`.
          NOTE = "! %<preamble>s%<requester>s asks to run %<tool>s(%<input>s)  -- answer in %<buffer>s, or /approve"
          UNANNOUNCED = "the chat could not announce a parked call (%<failure>s) -- lain://approval still lists it"

          def initialize(notice:)
            @notice = notice
            @announced = Set.new.compare_by_identity
          end

          def watch(queue)
            loop do
              sweep(queue)
              Async::Task.current.sleep(TICK)
            end
          end

          private

          # The snapshot is taken before anything is written, and a write is
          # where this fiber can yield, so a park or a settle landing mid-sweep
          # is met on the next tick rather than inside this one.
          def sweep(queue)
            parked = queue.reject(&:decided?)
            @announced.keep_if { |pending| parked.include?(pending) }
            parked.select { |pending| @announced.add?(pending) }.each { |pending| announce(pending) }
          end

          # Guarded for {Frontend::ApprovalPolicy#asked}'s reason: this fiber
          # announces every later call, and the likeliest raise is the terminal
          # going away -- unguarded it ended the watcher and left Async's own
          # warning in the chat pane. A call whose note failed is not retried;
          # lain://approval lists it regardless.
          def announce(pending)
            @notice.call(format(NOTE, preamble: pending.outstanding.preamble, requester: pending.requester,
                                      tool: pending.tool, input: pending.input.inspect,
                                      buffer: Frontend::Neovim::ApprovalView::BUFFER))
          rescue StandardError => e
            report(e)
          end

          # Through the same note, once, and swallowed if that fails too: a
          # terminal that cannot take the note cannot take the note about it.
          def report(error)
            @notice.call(format(UNANNOUNCED, failure: "#{error.class}: #{error.message}"))
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
