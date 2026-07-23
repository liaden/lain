# frozen_string_literal: true

require_relative "repl/approval_surfaces"

module Lain
  module CLI
    # One conversation: reads lines at `you>`, consults the command registry
    # first (T9), routes everything else through the repl phase, hosts the
    # fleet's reactor for the conversation's life, and delegates the ask_human
    # reply surfaces to {HumanReplies}. Extracted from the Thor class because a
    # conversation is its own responsibility (and the Metrics trip said so --
    # extract, do not loosen).
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
      # `commands:` is the T9 command surface -- a {Command::Registry::Bound},
      # the registry curried over the one frozen {Command::Env} Wiring
      # assembled -- consulted BEFORE the middleware phase, so a registered
      # `/word` never costs a model turn. `replies:` is the {HumanReplies}
      # drain Wiring wired over this same tty/conductor pair (injected, not
      # constructed here, so the Env's replies reader and this collaborator are
      # one object). Both required: a defaulted Null would let a mis-wired
      # session silently lose its command or reply surface.
      def initialize(agent:, tty:, replies:, commands:, chronicle:, conductor:, approvals: nil,
                     notifier: Lain::Notify::Null.new, supervisor: Lain::Supervisor::Null,
                     middleware: Lain::Middleware::Stack.new, auto_surface: nil,
                     goal_driver: Lain::CLI::GoalDriver::Null)
        @agent = agent
        @tty = tty
        @middleware = middleware
        @chronicle = chronicle
        @conductor = conductor
        @supervisor = supervisor
        @replies = replies
        @commands = commands
        @goal_driver = goal_driver
        # The approval-watching surfaces are their own collaborator now (the
        # TTY prompt, dunst, and the opt-in auto surface over one queue); Repl
        # asks it to `watch` and never touches the individual surfaces.
        @surfaces = ApprovalSurfaces.new(approvals:, notifier:, auto_surface:, tty:, conductor:)
      end

      # No next/break: the loop exit is text's own truthiness, reassigned each
      # pass, the same shape the project style favors elsewhere. Prompts read
      # through the conductor so an idle-prompt signal breaks out cleanly.
      # `first_prompt` (T17 /btw's --prompt seed) stands in for ONLY the first
      # read: the seeded question dispatches straight away, then next_text
      # resumes reading the terminal exactly as an unseeded chat does.
      def converse(first_prompt: nil)
        text = first_prompt || @conductor.read_prompt(@tty, "you> ")
        text = next_text(dispatch(text)) while continue?(text)
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
      # onto the reply surfaces before converse runs. `first_prompt` (T17) seeds
      # the child chat /btw opens with its --prompt question, threaded to
      # converse so the very first read is the side-question, not the terminal.
      def run(nvim:, store:, session:, first_prompt: nil)
        # T18: the bridge over the agent's own override slot, sharing the nvim
        # views' journal so the resend_dispatched marker lands beside the
        # request_resent projection it promotes.
        bridge = nvim && ResendBridge.new(agent: @agent, record: @chronicle,
                                          journal: nvim.fetch(:journal, Lain::Channel::Null.instance))
        frontend = nvim && Lain::Frontend::Neovim.new(store:, session:, resend_bridge: bridge, **nvim)
        @replies.bind_editor(frontend&.command_inbox)
        Sync do |task|
          @supervisor.run(task)
          @tty.run { frontend ? frontend.run { converse(first_prompt:) } : converse(first_prompt:) }
        ensure
          @supervisor.stop
        end
      end

      private

      def continue?(text) = text && !@conductor.closed? && !farewell?(text)

      # :quit -- the /quit command's action -- ends the conversation through
      # the SAME exit a bare "quit" takes: a nil text fails continue? exactly
      # as a farewell does, so run's ensures fire identically on both paths.
      # T21: the standing-goal driver is consulted BETWEEN asks, here, after a
      # turn has fully settled (respond returned, its approval/reply surfaces
      # stopped). A driving goal answers the next prompt -- the loop feeds it
      # like a typed line -- and yields an inline stop notice when it ends;
      # Null (no goal) answers nil cheaply, so the human prompt is read as
      # before.
      def next_text(action)
        return if action == :quit || @conductor.closed?

        @goal_driver.poll(@agent.timeline) { |notice| deliver_text(notice) } || @conductor.read_prompt(@tty, "you> ")
      end

      # Routes one typed line: the command registry FIRST (T9) -- a registered
      # `/word` runs lib-side with zero model turns and hands back rendered
      # text or a Repl action -- and everything else falls through to the
      # middleware phase unchanged. The boundary rescues Lain::Error raised
      # WITHIN EITHER PATH (a malformed invocation from the registry's parse or
      # the skill middleware's alike): render it and return, so `converse`
      # loops to the next prompt instead of dying.
      def dispatch(text)
        settle_command(@commands.dispatch(text) { middleware_turn(text) })
      rescue Lain::Error => e
        @tty.render_error(e.message)
        # Explicit: dispatch's return is #converse's ACTION position, and
        # render_error's own return value must never leak into it.
        nil
      end

      # A command's contract ({Command::Registry}): rendered TEXT -- a String,
      # delivered through the same boundary renderer a model turn uses, because
      # commands return text and never print -- or a Repl ACTION (:quit today),
      # handed up for #converse to act on. The middleware fallthrough settles
      # its own delivery and returns nil. Anything else is that command's bug;
      # name the breach loudly and RECOVERABLY, the render_missing_response
      # discipline.
      def settle_command(outcome)
        return outcome if outcome.nil? || outcome == :quit
        return deliver_text(outcome) if outcome.is_a?(String)

        @tty.render_error("command returned neither rendered text nor a Repl action: #{outcome.inspect}")
        # Explicit nil, as in dispatch's rescue: never render_error's return.
        nil
      end

      # A command's String rides the same Response shape SkillDispatch's
      # short-circuit uses, so render_response stays the single delivery
      # renderer for model turns, skill short-circuits, and commands alike. No
      # catch_up HERE: a command that moves the Timeline (T15's /rewind)
      # journals its own move through the chronicle before returning, so this
      # boundary owes the record nothing.
      def deliver_text(text)
        @tty.render_response(Response.new(content: [{ "type" => "text", "text" => text }], stop_reason: :end_turn))
        nil
      end

      # The middleware phase for a line no command claimed. `:text`/`:agent` go
      # in; the phase downstream runs the real ask and adds `:response` (nil on
      # a rescued Lain::Error) on the way out -- the same in/out shape
      # model_middleware uses for `:request`/`:response`.
      #
      # Delivery is this boundary's, not respond's: a middleware may
      # SHORT-CIRCUIT -- set `:response` and never call downstream -- and that
      # answer still has to reach the terminal, so the one renderer is here over
      # `env.response`, spent exactly once whether the response came from the
      # model turn or a middleware that skipped it. An error from the ask itself
      # is respond's own (it must journal the torn turns), so that path renders
      # and returns nil here -- no double. Returns nil ALWAYS, so only a
      # command can hand #converse an action.
      def middleware_turn(text)
        env = @middleware.call({ text:, agent: @agent }) do |inner|
          inner.merge(response: respond(inner.fetch(:text)))
        end
        env.to_h.key?(:response) ? deliver(env.response) : render_missing_response
        nil
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
          surfaces = [*@replies.surfaces(task), *@surfaces.watch(task)]
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

      def farewell?(text)
        %w[exit quit].include?(text.strip.downcase)
      end
    end
  end
end
