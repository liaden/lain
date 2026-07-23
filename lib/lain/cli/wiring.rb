# frozen_string_literal: true

require_relative "wiring/base_tools"

module Lain
  module CLI
    # The chat-assembly responsibility, lifted out of the Thor class the way Repl
    # was: assembling a chat's Agent -- its toolset, subagent, approval gate,
    # provider spool, and the ask_human reply seam -- is its own job (and the
    # Metrics trip said so: extract, do not loosen). Constructed with what it
    # needs (the flags, and the chronicle whose lifecycle #chat owns); it hands
    # back the built Agent, and exposes @ask_human/@questions so #run_chat can
    # give the Repl the reply path this object wired.
    class Wiring
      attr_reader :ask_human, :questions, :notifier, :supervisor, :role_spawn, :conductor, :auto_surface

      # The parked-approval queue, nil under --yolo -- the {Switchboard}'s now,
      # kept as a Wiring accessor because the Repl and exe read it here.
      def approvals = @switchboard&.approvals

      # The frozen {Command::Env} the run's {Command::Surface} assembled once.
      def command_env = @command_surface.env

      # `tty_factory:`/`conductor_opener:` are #run's construction seams (T9,
      # from the T1 panel note): the exe takes the real defaults; a spec hands
      # in a StringIO-backed TTY factory or a recording opener and drives #run
      # itself -- no send(:build_repl), no instance_variable_set.
      def initialize(options:, chronicle:, status_feed: Command::Env::NullStatus,
                     tty_factory: Lain::Frontend::TTY.public_method(:new),
                     conductor_opener: Lain::CLI::Conductor.public_method(:open))
        @options = options
        @chronicle = chronicle
        @status_feed = status_feed
        @tty_factory = tty_factory
        @conductor_opener = conductor_opener
      end

      # Assemble the run's collaborators over the now-open chronicle and hand off
      # to the frontend. The conductor guards the whole conversation: traps
      # installed around it, every ask supervised through the shutdown
      # coordinator. @conductor is set BEFORE the repl blocks, so the exe's
      # ensure can close it even when the repl raises mid-run; the block is the
      # exe's `say`, the one output seam this class is lent.
      def run(backend:, resumed:, nvim:, &notice)
        channel = Lain::Channel.new
        recorder, session = run_state(resumed)
        agent = wire_agent(channel:, recorder:, session:, backend:, resumed:)
        resumed&.notices&.each(&notice)
        tty = @tty_factory.call(channel:)
        @conductor = @conductor_opener.call(tty:, chronicle: @chronicle, grace: @options[:grace], supervisor:)
        @conductor.guard do
          build_repl(tty:, agent:).run(nvim:, store: agent.timeline.store, session:,
                                       first_prompt: @options[:prompt])
        end
      end

      # The subagent tool reads the live parent head at spawn time, so the Agent is
      # late-bound through a thunk: the closure captures the BINDING, and `agent` is
      # assigned after the toolset that closes over it. The SAME recorder backs the
      # session's manifest and the read/write tools -- one index, three views.
      # The chronicle starts here -- after the toolset (its header pins the
      # finished schema), before the Agent (whose turn middleware records through
      # it). A resumed chat threads the chained-header fields (resumed_from/written)
      # into that header and seeds the Agent with the resumed Timeline.
      # The recorder and the journaled Session, fresh or resumed. One Recorder
      # backs the memory_write tool for the whole session -- the single mutable
      # holder of the live Memory::Index, so each write supersedes the last (its
      # prior root still resolves the old item); a resumed chat inherits the
      # chain-wide recorder instead, so its manifest sees every memory the
      # resumed sessions wrote. The chronicle then decorates both run-state
      # seams: reads/todos journal through Session::Journaled, and each
      # turn_usage pairs with the memory root in force (JournalMemoryRoot) --
      # identity under --no-journal.
      def run_state(resumed)
        recorder = resumed ? resumed.recorder : Lain::Memory::Recorder.new
        session = resumed ? resumed.session : Lain::Session.new(memory: recorder, worker_env: Lain::WorkerEnv.default)
        chronicle.wrap_memory(recorder)
        [recorder, chronicle.wrap_session(session)]
      end

      def wire_agent(channel:, recorder:, session:, backend:, resumed: nil)
        agent = nil
        parent = -> { agent.timeline }
        @notifier = Lain::Notify.for
        # OM-6: the reactor above the Agent that un-refuses model-dispatched
        # actors. Journals a bounded drain's timeout to the live Channel; the exe
        # #run_chat below runs it under a chat-level reactor that outlives asks.
        @supervisor = Lain::Supervisor.new(journal: channel)
        @ask_human = notifying_ask_human(parent)
        toolset = build_toolset(recorder, backend:, parent:, journal: channel, ask_human: @ask_human)
        chronicle.start(context: backend.context, toolset:, **resume_start(resumed))
        build_agent(toolset:, channel:, session:, backend:, timeline: resumed&.timeline)
      end

      private

      attr_reader :options, :chronicle

      # A resumed chat opens its NEW journal chained to the old one; a fresh chat
      # passes nothing, and the scribe writes an unchained header. Derived from
      # the Resume result so the exe never assembles the wire-format hashes.
      def resume_start(resumed) = resumed ? { resumed_from: resumed.resumed_from, written: resumed.written } : {}

      # The replier fiber (see Repl#answer_loop) parks on @questions and answers
      # through @ask_human -- Wiring-instance state because the reply path and the
      # toolset are wired in different methods of this one assembly. The enqueue
      # happens inside #ask (before perform's await), and Async::Queue is
      # buffered, so the replier never misses a question. The observer routes the
      # Q/A :message events into the session record -- a Timeline walk can never
      # find them.
      def notifying_ask_human(parent)
        @questions = Async::Queue.new
        Lain::Tools::AskHuman::Notifying.new(notify: ->(question) { announce(question) }, parent:,
                                             observer: chronicle.observer)
      end

      # I5: fans the existing enqueue-for-the-TTY-replier seam out to ALSO fire a
      # desktop notification naming the asking agent. Notify::Null under no
      # dunstify on PATH, so this stays one call site regardless of the desktop.
      def announce(question)
        @questions.enqueue(question)
        @notifier.question(agent: "lain", text: question)
      end

      def build_toolset(recorder, backend:, parent:, journal:, ask_human:)
        base = Lain::Toolset.new(BaseTools.build(recorder))
        @role_spawn = role_spawn_seam(base, backend:, parent:, journal:)
        # T12: opt-in third approval surface, over the SAME role_spawn seam a
        # `@role/skill` line folds through -- nil without --auto-approve, so
        # Repl's approval_loop wires nothing extra by default.
        @auto_surface = (Lain::Approval::AutoSurface.new(role_spawn: @role_spawn) if @options[:auto_approve])
        Lain::Toolset.new(base.to_a + [research_subagent(base, backend:, parent:, journal:), ask_human, run_skill])
      end

      # The repl-phase role-spawn seam (a @role/skill line folds a persona'd
      # one-shot subagent through this). It attenuates from the SAME base union the
      # research subagent does, over the same spooled provider, child context, live
      # parent handle, journal, supervisor, and lineage observer -- the
      # role/policy/persona are chosen PER CALL from the parsed role name and
      # context mode, so one seam serves every role. `slots:` is the session's
      # rendered-persona source (Backend#slots, loaded once).
      def role_spawn_seam(base, backend:, parent:, journal:)
        Lain::Skill::RoleSpawn.new(toolset: base, slots: backend.slots,
                                   **child_seam_kwargs(backend, parent:, journal:))
      end

      # The collaborators BOTH child seams (role spawn above, the research
      # subagent below) attenuate over -- the same spooled provider, child
      # context, live parent handle, journal, supervisor, and lineage observer.
      # One helper, so the sentence "over the same seams" is code, not a
      # comment that can drift.
      def child_seam_kwargs(backend, parent:, journal:)
        { provider: spooled_provider(backend), context_factory: -> { backend.context },
          parent:, journal:, supervisor: @supervisor, observer: chronicle.observer }
      end

      # The in-agent composition primitive, main-agent-only: appended AFTER `base`
      # (like ask_human), never inside base_tools, so the union a subagent role
      # attenuates from does not carry it. It renders a skill's scaffold back to the
      # SAME agent as a tool_result -- a continuation, not a spawn. The renderer is
      # built over the same catalog + slots the repl's ReplMiddleware composes,
      # loaded once from the project root.
      def run_skill = Lain::Tools::RunSkill.new(renderer: ReplMiddleware.renderer)

      # The chat default: an attenuated read-only child (schema posture, depth 1).
      # The observer routes its :spawn/:message lineage events into the session
      # record, exactly as ask_human's Q/A goes.
      def research_subagent(base, backend:, parent:, journal:)
        Lain::Tools::Subagent.new(toolset: base, policy: backend.spawn_policy(:researcher), max_depth: 1,
                                  **child_seam_kwargs(backend, parent:, journal:))
      end

      # Gate and Live share ONE Toolset (the single-map invariant the plan
      # calls out): a second Toolset reference here could let the approval gate
      # and the executor disagree about what a tool name means. RefuseSecretWrites
      # sits in the tool phase so a credential-shaped memory_write is withheld
      # before it ever reaches the recorder (a memory, once indexed, replays into
      # every future context -- there is no un-indexing it).
      # `session:` is REQUIRED, not defaulted: a defaulted fresh Session would
      # silently mis-wire memory -- a caller passing a recorder-bearing toolset
      # but forgetting session: would get working memory tools with a permanently
      # blind manifest. Forgetting must be a loud ArgumentError, not a quiet
      # degrade (T1 panel, Schneeman).
      # Telemetry (TurnUsage via journal:, RequestSent via the JournalRequests
      # phase) and per-iteration turn durability both come from the chronicle;
      # under --nvim they fan through the tee to the live views too. The `tap`
      # gives the turn middleware's thunk the same late-bound agent binding the
      # subagent's parent handle uses. `timeline:` seeds a resumed chat's Agent
      # with the chain-verified Timeline (nil = Agent's fresh default).
      def build_agent(toolset:, channel:, session:, backend:, timeline: nil)
        board = switchboard(backend)
        gate = board.gate(inner: Lain::Effect::Handler::Live.new(toolset:, channel:))

        agent = nil
        Lain::Agent.new(provider: spooled_provider(backend, channel:), toolset:,
                        context: board.graft(backend.context),
                        handler: gate, session:, timeline:,
                        tool_middleware: Lain::Middleware::Stack.new([Lain::Middleware::RefuseSecretWrites.new]),
                        turn_middleware: chronicle.turn_middleware(-> { agent.timeline }),
                        **chronicle.telemetry_kwargs).tap { |built| agent = built }
      end

      # Both provider construction sites tee their round trips into the
      # chronicle's response spool (see Lain::CLI::Chronicle#spool) -- a real
      # ResponseWal when journaling, the Null spool under --no-journal. `channel:`
      # is the live TTY Channel for the MAIN agent (CE-5 stream_started reaches
      # the frontend); a subagent leaves the Null default -- its stream is not
      # rendered, only the spool tee matters there.
      def spooled_provider(backend, channel: Lain::Channel::Null.instance)
        backend.provider(spool: chronicle.spool, channel:)
      end

      # I4/T14: the {Switchboard} owns Gate's policy now -- the queue (or
      # ApproveAll under --yolo) behind the ONE PolicySwitch /yolo flips; Gate
      # itself stays construction-fixed. It resolves its own journal from the
      # chronicle (the null device under --no-journal). Memoized where
      # build_agent first needs it, so the direct build_agent seam the specs
      # drive assembles it too.
      def switchboard(backend)
        @switchboard ||= Switchboard.for(chronicle:, options:, model: backend.context.model)
      end

      # The Repl over the run's collaborators -- the accessors are this class's
      # own seams (it wired the toolset @ask_human/@questions belong to), so the
      # Repl reads them here rather than through exe-instance state. The
      # {HumanReplies} drain is built HERE (not inside Repl) so the Env's
      # replies reader and the Repl's collaborator are one object; everything a
      # typed line dispatches through -- command registry, frozen Env, skill
      # middleware, one shared catalog -- is {Command::Surface}'s (T9).
      def build_repl(tty:, agent:)
        replies = HumanReplies.new(tty:, conductor: @conductor, ask_human:, questions:)
        @command_surface = Command::Surface.new(agent:, replies:, supervisor:, role_spawn:, approvals:,
                                                chronicle: @chronicle, status_feed: @status_feed,
                                                **@switchboard.surface_kwargs(conductor: @conductor, tty:))
        Repl.new(agent:, tty:, replies:, chronicle: @chronicle, conductor: @conductor, approvals:, notifier:,
                 supervisor:, middleware: @command_surface.middleware, commands: @command_surface.commands,
                 auto_surface:)
      end
    end
  end
end
