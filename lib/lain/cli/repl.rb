# frozen_string_literal: true

require_relative "repl/approval_surfaces"
require_relative "repl/ask"
require_relative "repl/conversation_scope"
require_relative "repl/line_scope"
require_relative "repl/outcome"

module Lain
  module CLI
    # One conversation: reads lines at `you>`, consults the command registry
    # first, routes everything else through the repl phase, hosts the fleet's
    # reactor for the conversation's life, and delegates the ask_human reply
    # surfaces to {HumanReplies}. Extracted from the Thor class because a
    # conversation is its own responsibility -- the Metrics trip said so.
    class Repl
      # The keywords with no default are required for one reason: a defaulted
      # Null would let a mis-wired session silently lose its session record, its
      # command surface or its reply drain, with no error anywhere.
      #
      # `commands:` is consulted BEFORE the middleware phase, so a registered
      # `/word` never costs a model turn. False for the attended keyword
      # (`--non-interactive`) makes the seeded question the WHOLE conversation:
      # nothing reads a second line, so the run ends where an attended one would
      # go back to the prompt.
      def initialize(agent:, tty:, replies:, commands:, chronicle:, conductor:, approvals: nil,
                     supervisor: Lain::Supervisor::Null,
                     middleware: Lain::Middleware::Stack.new, auto_surface: nil, secret_surface: nil,
                     goal_driver: Lain::CLI::GoalDriver::Null, attended: true)
        @agent = agent
        @tty = tty
        @middleware = middleware
        @chronicle = chronicle
        @conductor = conductor
        @replies = replies
        @commands = commands
        @goal_driver = goal_driver
        @attended = attended
        name_lifetimes(replies:, supervisor:, approvals:, auto_surface:, secret_surface:, tty:, conductor:)
      end

      # What this conversation was worth as a process exit status, for the one
      # caller entitled to ask (`lain chat --non-interactive`). An attended chat
      # says the same words at the terminal and exits 0 regardless.
      def exit_status = outcome.exit_status

      # Hoisted out of {#render_missing_response} so that method stays the one
      # line it reads as.
      MIDDLEWARE_BREACH = "repl middleware short-circuited without setting :response"

      # No next/break: the loop exit is text's own truthiness, reassigned each
      # pass. Prompts read through the conductor so an idle-prompt signal breaks
      # out cleanly. `first_prompt` (the `/btw` child's `--prompt` seed) stands
      # in for ONLY the first read; an unattended conversation is the same shape
      # with the reading taken out at both ends, so the seed is its only line.
      def converse(first_prompt: nil)
        text = first_prompt || (prompt.read if reads_a_line?)
        text = next_text(dispatch(text)) while continue?(text)
      end

      # Run the conversation inside the terminal frontend, nested inside the
      # optional Neovim frontend when one is attached. Both frontends' ensures --
      # nvim's RPC stop+join, in that order, and tty#run's screen restore -- run
      # when converse returns, including a signal-ended session.
      #
      # The supervisor's reactor must OUTLIVE each per-ask Sync (an actor
      # launched inside an ask's Sync would be that ask's captive child), so one
      # chat-level Sync here gives every inner ask the shared reactor and the
      # fleet a home across asks.
      #
      # The editor's gesture rail is consumed HERE, for the conversation, and
      # not by {#respond} for one ask: a human marking hunks in a review does it
      # between turns, so an ask-scoped consumer answers nothing while they work
      # -- and the rail is their only signal a gesture landed. {ConversationScope}
      # owns that lifetime, closed by the ensure on every path out.
      #
      # `epic:` is what the editor's lain://status draws, resolved by {Wiring};
      # like `store:` and `session:` it reaches only the frontend built here.
      def run(nvim:, store:, session:, first_prompt: nil, epic: Lain::Frontend::Neovim::StatusView::Unmounted)
        frontend = attach_editor(nvim, store:, session:, epic:)
        @replies.bind_editor(frontend&.command_inbox, views: frontend&.buffers, approvals: frontend&.approval_view)
        # The frontend ITSELF, not a piece of it: a changeset review needs three
        # things no single collaborator answers -- where the diff is drawn, the
        # rendering a row gesture resolves through, and the rail its writes are
        # answered on.
        @replies.bind_review_editor(frontend)
        @prompt = composed_prompt(frontend)
        Sync do |task|
          @conversation.open(task)
          @tty.run { frontend ? frontend.run { converse(first_prompt:) } : converse(first_prompt:) }
        ensure
          @conversation.close
        end
      end

      private

      # The three lifetimes a conversation runs, each named by the object that
      # owns it -- so which fiber belongs to which, and who stops it, is read
      # off a name rather than off three ensures. {ConversationScope} is the
      # longest (the fleet's reactor and the editor's gesture consumer);
      # {LineScope} is the middle one, live for ONE dispatched line, because a
      # question can be raised from any frame a line reaches and not only from
      # the ask.
      def name_lifetimes(replies:, supervisor:, **approval_seams)
        @surfaces = ApprovalSurfaces.new(**approval_seams)
        @conversation = ConversationScope.new(supervisor:, replies:)
        @line = LineScope.new(replies:, surfaces: @surfaces)
      end

      # The bridge over the agent's own override slot, sharing the nvim views'
      # journal so the resend_dispatched marker lands beside the request_resent
      # projection it promotes. The compose_notify keyword is what makes the
      # compose round trip's notices reachable -- its default is silent, so
      # without it an abandoned compose ends with no signal at all.
      #
      # The editor's approval list is bound HERE rather than in #run because
      # this is the method that knows whether an editor exists at all: the view
      # is built BY the frontend, so nil means there is nothing to construct
      # rather than a capability left unwired, and it is what leaves the fourth
      # watch fiber unspawned for a headless chat.
      def attach_editor(nvim, store:, session:, epic:)
        bridge = nvim && ResendBridge.new(agent: @agent, record: @chronicle,
                                          journal: nvim.fetch(:journal, Lain::Channel::Null.instance))
        frontend = nvim && Lain::Frontend::Neovim.new(store:, session:, epic:, resend_bridge: bridge,
                                                      compose_notify: @tty.method(:render_warning), **nvim)
        @surfaces.bind_editor(frontend&.approval_view)
        frontend
      end

      # A prompt that reads and nothing more, for the paths that never build a
      # frontend. Lazy so that constructing a Repl neither builds a frontend nor
      # -- crucially -- rebinds the human's keyboard; #run overwrites `@prompt`
      # before any read, and binding happens only there.
      def prompt
        @prompt ||= ComposedPrompt.new(conductor: @conductor, tty: @tty,
                                       compose: Lain::Frontend::Neovim::Compose.new)
      end

      # Built here rather than injected: the compose object hangs off the
      # frontend, and #run is the first thing to hold one.
      def composed_prompt(frontend)
        compose = frontend&.compose ||
                  Lain::Frontend::Neovim::Compose.new(notify: @tty.method(:render_warning))
        ComposedPrompt.new(conductor: @conductor, tty: @tty, compose:).tap(&:bind_key)
      end

      def continue?(text) = text && !@conductor.closed? && !farewell?(text)

      # :quit ends the conversation through the SAME exit a bare "quit" takes: a
      # nil text fails continue? exactly as a farewell does, so run's ensures
      # fire identically on both paths. The standing-goal driver is consulted
      # BETWEEN asks, after a turn has fully settled and its surfaces stopped; a
      # driving goal answers the next prompt as a typed line would, and Null (no
      # goal) answers nil cheaply so the human prompt is read as before.
      #
      # A line the human typed while the last one dispatched, and was told was
      # HELD ({HumanReplies#hold}), comes first: it was typed before anything
      # the driver would say next, and it is what a human who typed it expects
      # to run.
      def next_text(action)
        return if action == :quit || !reads_a_line?

        @replies.take_held || @goal_driver.poll(@agent.timeline) { |notice| deliver_text(notice) } || prompt.read
      end

      # Whether any line is coming: not once the conductor has closed the
      # session, and never at all when nobody is at the terminal.
      def reads_a_line? = @attended && !@conductor.closed?

      # See {Outcome} for why it is sticky.
      def outcome = @outcome ||= Outcome.new

      # Routes one typed line: the command registry FIRST -- a registered
      # `/word` runs lib-side with zero model turns -- and everything else falls
      # through to the middleware phase unchanged. The rescue covers BOTH paths,
      # so a malformed invocation renders and `converse` loops to the next
      # prompt instead of dying.
      #
      # It is also the frame the human's answer surfaces are bracketed over,
      # because a question or a parked approval can be raised from either path
      # and the fiber that parks on one is this one. {LineScope} holds the
      # reason the line is the right lifetime, and the invariant `serves_replies?`
      # answers here: a line which reads the terminal ITSELF gets no surface
      # spawned over it, and the question costs no side effect.
      def dispatch(text)
        @line.serve(owns_terminal: @commands.serves_replies?(text)) do
          settle_command(@commands.dispatch(text) { middleware_turn(text) }, text)
        end
      rescue Lain::Error => e
        @tty.render_error(outcome.note(e).message)
        # Explicit: dispatch's return is #converse's ACTION position, and
        # render_error's own return value must never leak into it.
        nil
      end

      # A command's contract ({Command::Registry}): rendered TEXT (a String,
      # delivered through the same boundary renderer a model turn uses, because
      # commands return text and never print), a {Lain::Renderable}, or a Repl
      # ACTION (:quit today) for #converse to act on. The middleware
      # fallthrough settles its own delivery and returns nil. Anything else is
      # that command's bug; name the breach loudly and RECOVERABLY.
      #
      # `returned`, not `outcome`: a parameter of that name would shadow the
      # private {#outcome} reader for the length of this method -- the same
      # collision {#respond}'s `supervised` local avoids one method down.
      def settle_command(returned, text)
        return returned if returned.nil? || returned == :quit
        return deliver_text(returned) if returned.is_a?(String)
        return deliver_rendered(returned) if returned.is_a?(Renderable)

        @tty.render_error("command #{called(text)} returned neither a renderable, " \
                          "rendered text, nor a Repl action: #{returned.inspect}")
        nil
      end

      # The `/word` the human typed, so a breach says WHICH command misbehaved.
      # Split off the typed line rather than re-running {Skill::Invocation.parse}:
      # only a line the registry already matched reaches here, so its leading
      # word is the command by construction and a second parse could only disagree.
      def called(text) = text.to_s.split.first

      # A command's String rides the same Response shape SkillDispatch's
      # short-circuit uses, so render_response stays the single delivery
      # renderer for model turns, skill short-circuits, and commands alike. No
      # catch_up HERE: a command that moves the Timeline (/rewind) journals its
      # own move before returning, so this boundary owes the record nothing.
      def deliver_text(text)
        @tty.render_response(Response.new(content: [{ "type" => "text", "text" => text }], stop_reason: :end_turn))
        nil
      end

      # A renderable does NOT ride deliver_text's synthetic Response: a Response
      # carries text blocks, so wrapping one would flatten the segments back
      # into the single string render_response paints with one token -- exactly
      # the information the renderable exists to keep. Returns nil like its
      # sibling, so only a Repl action ever reaches #converse.
      def deliver_rendered(renderable)
        @tty.render_renderable(renderable)
        nil
      end

      # The middleware phase for a line no command claimed. Delivery is this
      # boundary's, not respond's: a middleware may SHORT-CIRCUIT -- set
      # `:response` and never call downstream -- and that answer still has to
      # reach the terminal, so the one renderer is here, spent exactly once
      # whichever produced it. An error from the ask itself is respond's own (it
      # must journal the torn turns), so that path renders and returns nil here.
      # Returns nil ALWAYS, so only a command can hand #converse an action.
      #
      # THE WHOLE PHASE IS SUPERVISED, not only the model turn inside it. A
      # middleware that answers without a turn can run for minutes -- a
      # critique spawns a child per chunk -- and outside {Conductor#supervise}
      # every signal routes to `Signals::NULL`, so the human's Ctrl-C reached
      # nothing. One supervision per line, so a pass-through line's turn is
      # supervised by it and {#respond} opens no second one.
      #
      # A nil response is a STOPPED run: the block always hands back an env or
      # a refusal, and only a stop leaves the task with no value. The conductor
      # has already journaled the stop and closed the session, so what is left
      # is marking the line unfinished.
      def middleware_turn(text)
        supervised = supervise_line(text)
        # The supervisor's own refusal, already said and recorded in full.
        return if supervised.nil?

        env = supervised.response
        raise env if env.is_a?(Lain::Error)
        return deliver(outcome.note(nil)) if env.nil? && supervised.closed?

        env.to_h.key?(:response) ? deliver(env.response) : render_missing_response
        nil
      end

      # A {Lain::Error} raised by the SUPERVISOR itself, outside the task, is
      # owed the one line an ask's refusal gets, and nothing is left to deliver:
      # the nil this answers then is {#middleware_turn}'s cue to stop.
      def supervise_line(text)
        Sync { |task| @conductor.supervise(task, -> { @agent.timeline }) { middleware_env(text) } }
      rescue Lain::Error => e
        Ask.new(agent: @agent, tty: @tty, chronicle: @chronicle).settle(outcome.note(e))
      end

      # A middleware's own refusal comes OUT of the supervised task as a value,
      # for {Ask}'s measured reason: raised inside it, Async reports a task that
      # "ended with an unhandled exception" before the one line the human is
      # owed. {#middleware_turn} raises it again OUTSIDE, where {#dispatch}
      # renders it as it always has.
      def middleware_env(text)
        @middleware.call({ text:, agent: @agent }) do |inner|
          inner.merge(response: respond(inner.fetch(:text)))
        end
      rescue Lain::Error => e
        e
      end

      # A middleware that short-circuits WITHOUT setting `:response` is a bug in
      # that middleware, not a reason to kill the REPL: `env.response` (fetch)
      # would raise KeyError -- NOT a Lain::Error, so dispatch's rescue misses
      # it and it escapes converse. Guard the contract loudly and RECOVERABLY.
      # A PRESENT `:response` of nil is not this case: absence is the bug, nil
      # is a choice.
      def render_missing_response = @tty.render_error(outcome.torn_by(MIDDLEWARE_BREACH))

      # The model turn, returned for {#dispatch} to deliver -- never rendered
      # here, so a short-circuiting middleware's response and this one share the
      # single boundary renderer. It runs inside the line's supervision
      # ({#middleware_turn}), whose task the concurrent surfaces an ask needs are
      # already live beside: {LineScope} starts them for the whole dispatched
      # line. They must be concurrent at all because `ask` parks inside
      # ask_human#perform awaiting a reply from this same terminal, and a
      # single-fiber ask-then-prompt deadlocks.
      #
      # A TORN ASK IS {Ask}'S, not this method's. It runs the ask too, so a
      # refusal comes back as a VALUE rather than killing the `Async::Task`
      # {Conductor#supervise} ran the line in -- read its class doc for why,
      # because that reason is measured and is not visible from here. A stopped
      # ask never returns here at all: the stop unwinds the whole line, and
      # {#middleware_turn} settles it.
      def respond(text)
        ask = Ask.new(agent: @agent, tty: @tty, chronicle: @chronicle)
        ask.settle(outcome.note(ask.attempt(text)))
      end

      # Turns durable before the reply renders: the belt over the chronicle's
      # per-iteration braces (idempotent), and it re-anchors the head a graceful
      # close records.
      def deliver(response)
        @chronicle.catch_up(@agent.timeline)
        @tty.render_response(response) if response
      end

      def farewell?(text) = %w[exit quit].include?(text.strip.downcase)
    end
  end
end
