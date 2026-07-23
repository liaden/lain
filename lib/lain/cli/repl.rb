# frozen_string_literal: true

module Lain
  module CLI
    # One conversation: reads commands at `you>`, routes each through the repl
    # phase, hosts the fleet's reactor for the conversation's life, and delegates
    # the ask_human reply surfaces to {HumanReplies}. Extracted from the Thor
    # class because a conversation is its own responsibility (and the Metrics
    # trip said so -- extract, do not loosen).
    class Repl
      # `chronicle:` is required, not defaulted -- the same reasoning as
      # build_agent's `session:`: a defaulted Null here would let a caller
      # silently lose the session record with no error anywhere. `middleware:`
      # is the repl phase: a Middleware::Stack wrapping EACH command typed at
      # the prompt, the seam a future history/logging/confirmation phase lands
      # on; an honest pass-through by default. `notifier:` is the I5 desktop
      # surface watching the SAME approval queue the TTY prompt does (first
      # answer wins); Null when no dunstify, so the second watch fiber is inert.
      # `supervisor:` is the OM-6 fleet reactor #run hosts across asks.
      def initialize(agent:, tty:, ask_human:, questions:, chronicle:, conductor:, approvals: nil,
                     notifier: Lain::Notify::Null.new, supervisor: Lain::Supervisor::Null,
                     middleware: Lain::Middleware::Stack.new)
        @agent = agent
        @tty = tty
        @middleware = middleware
        @chronicle = chronicle
        @conductor = conductor
        @approvals = approvals
        @notifier = notifier
        @supervisor = supervisor
        @replies = HumanReplies.new(tty:, conductor:, ask_human:, questions:)
        @approval_surface = approval_surface
      end

      # WHY the reader routes through the conductor: a bare `@input.gets` in
      # the surface fiber races answer_loop's Reline read for the one stdin,
      # escapes the conductor's countdown-ticker suppression (read_reply
      # exists precisely so the ticker's render + key-read pause while a
      # human types), and -- being a thread-blocking, non-scheduler read --
      # freezes the whole reactor, so the queue's fail-closed timer could
      # NEVER fire while the prompt sat unanswered. read_reply parks the
      # fiber instead: prompts serialize with ask_human replies, and an
      # unattended prompt still times out to denial.
      def approval_surface
        Lain::Frontend::ApprovalPolicy.new(
          reader: ->(prompt) { @conductor.read_reply(@tty, prompt) }
        )
      end

      # No next/break: the loop exit is text own truthiness, reassigned each
      # pass, the same shape the project style favors elsewhere. Prompts read
      # through the conductor so an idle-prompt signal breaks out cleanly.
      def converse
        text = @conductor.read_prompt(@tty, "you> ")
        while continue?(text)
          dispatch(text)
          text = @conductor.closed? ? nil : @conductor.read_prompt(@tty, "you> ")
        end
      end

      # Run the conversation inside the terminal frontend, nested inside the optional
      # Neovim frontend when one is attached (`nvim:` carries its wiring bits, or nil).
      # Both frontends' ensures -- nvim's RPC stop+join (T9 order) and tty#run's screen
      # restore -- run when converse returns, including a signal-ended session.
      # OM-6: the supervisor's reactor must OUTLIVE each per-ask Sync (an actor
      # launched inside an ask's Sync would be that ask's captive child), so one
      # chat-level Sync here gives every inner ask the shared reactor and the
      # fleet a home across asks. supervisor.stop farewells the fleet before the
      # reactor closes; the drain-on-shutdown itself is wired lib-side through
      # the conductor. The editor's :LainReply queue (or nil, no editor) is bound
      # onto the reply surfaces before converse runs.
      def run(nvim:, store:, session:)
        frontend = nvim && Lain::Frontend::Neovim.new(store:, session:, **nvim)
        @replies.bind_editor(frontend&.command_inbox)
        Sync do |task|
          @supervisor.run(task)
          @tty.run { frontend ? frontend.run { converse } : converse }
        ensure
          @supervisor.stop
        end
      end

      private

      def continue?(text) = text && !@conductor.closed? && !farewell?(text)

      # Routes one typed command through the repl phase. `:text`/`:agent` go in;
      # the phase downstream runs the real ask and adds `:response` (nil on a
      # rescued Lain::Error) on the way out -- the same in/out shape
      # model_middleware uses for `:request`/`:response`.
      #
      # Delivery is dispatch's, not respond's: a middleware may SHORT-CIRCUIT --
      # set `:response` and never call downstream -- and that answer still has to
      # reach the terminal, so the one renderer is here at the boundary over
      # `env.response`, spent exactly once whether the response came from the
      # model turn or a middleware that skipped it. The boundary also rescues
      # Lain::Error raised WITHIN THE CHAIN (a malformed skill invocation, say):
      # render it and return, so `converse` loops to the next prompt instead of
      # dying. An error from the ask itself is respond's own (it must journal the
      # torn turns), so that path renders and returns nil here -- no double.
      def dispatch(text)
        env = @middleware.call({ text:, agent: @agent }) do |inner|
          inner.merge(response: respond(inner.fetch(:text)))
        end
        env.to_h.key?(:response) ? deliver(env.response) : render_missing_response
      rescue Lain::Error => e
        @tty.render_error(e.message)
      end

      # The repl phase's out-key is `:response` (Env's per-phase contract): the
      # downstream ask sets it, and a short-circuiting middleware MUST set it too.
      # One that short-circuits WITHOUT it is a bug in that middleware, not a
      # reason to kill the REPL: `env.response` (fetch) would raise KeyError --
      # NOT a Lain::Error, so dispatch's rescue misses it and it escapes converse.
      # Guard the contract loudly and RECOVERABLY -- name the breach to the
      # terminal and let converse read the next prompt. A PRESENT `:response` of
      # nil is not this case (an explicit-nil short-circuit renders nothing via
      # deliver's own guard); absence is the bug, nil is a choice -- so never a
      # silent nil deliver here.
      def render_missing_response
        @tty.render_error("repl middleware short-circuited without setting :response")
      end

      # The model turn, returned for {#dispatch} to deliver -- never rendered
      # here, so a short-circuiting middleware's response and this one share the
      # single boundary renderer. Concurrent surfaces beside the ask: the
      # {HumanReplies} reply fibers (`ask` parks inside ask_human#perform awaiting
      # the reply, and the reply comes from this same terminal -- a single-fiber
      # ask-then-prompt deadlocks, OM-4 depends on OM-0) and the approval
      # watchers. Every surface `.stop` in the ensure is load-bearing: a parked
      # one holds Sync open forever otherwise. A torn ask is journaled and
      # rendered right here (it owns the interrupted record), then returns nil so
      # dispatch delivers nothing over it.
      def respond(text)
        Sync do |task|
          surfaces = [*@replies.surfaces(task), *approval_loop(task)]
          @conductor.supervise(task, -> { @agent.timeline }) { @agent.ask(text) }.response
        ensure
          surfaces&.each { |surface| surface&.stop }
        end
      rescue Lain::Error => e
        record_interruption
        @tty.render_error(e.message)
        nil
      end

      # Turns durable before the reply renders: the belt over the chronicle's
      # per-iteration JournalTurns braces (idempotent), and it re-anchors the
      # head a graceful close records.
      def deliver(response)
        @chronicle.catch_up(@agent.timeline)
        @tty.render_response(response) if response
      end

      # B5 (panel amendment): catch_up FIRST -- a raise can land AFTER commits
      # (the ask tore mid-loop), so the committed turns are journaled before the
      # stop is recorded, and interrupted then names the true last commit.
      def record_interruption
        @chronicle.catch_up(@agent.timeline)
        @chronicle.interrupted(head: @agent.timeline.head_digest)
      end

      # Two surfaces now watch the SAME queue -- the TTY prompt and dunst --
      # first answer wins (Pending's own doctrine). Nil under --yolo (no queue),
      # so neither watch fiber spawns; the notifier is Null with no dunstify.
      def approval_loop(task)
        @approvals && [task.async { @approval_surface.watch(@approvals) },
                       task.async { @notifier.watch(@approvals) }]
      end

      def farewell?(text)
        %w[exit quit].include?(text.strip.downcase)
      end
    end
  end
end
