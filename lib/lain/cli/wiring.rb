# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

require_relative "wiring/base_tools"
require_relative "wiring/toolset_build"

module Lain
  module CLI
    # The chat-assembly responsibility, lifted out of the Thor class the way Repl
    # was: assembling a chat's Agent -- its toolset, subagent, approval gate,
    # provider spool, and the ask_human reply seam -- is its own job (and the
    # Metrics trip said so: extract, do not loosen). Constructed with what it
    # needs (the flags, and the chronicle whose lifecycle #chat owns); it hands
    # back the built Agent, and exposes @ask_human/@questions so #run_chat can
    # give the Repl the reply path this object wired.
    #
    # ⚠️ THIS CLASS IS NEAR ITS 110-LINE Metrics/ClassLength BUDGET. Measure it
    # (`rubocop --only Metrics/ClassLength`) rather than trusting a number
    # written here; the last two cards left it in single-digit headroom, which is
    # not room for a feature: EXTRACT FIRST.
    #
    # It has been through that twice. It sat a year at 109, reached 110 exactly,
    # and that is what forced {ToolsetBuild} out of it (T1 review): "what
    # capabilities this run holds, and how a child inherits them" was never this
    # object's question, and the tell was a `(backend:, parent:, journal:)`
    # triple threaded verbatim through three private methods -- a repeated
    # parameter list is the state of an object that has not been named yet. The
    # same tell then appeared on the `(catalog:, slots:)` pair T15 threaded into
    # {Command::Surface} and {ToolsetBuild}, and T40 named it {Skill::Library}:
    # one `.lain/` read, owned by {Backend#library} because {Backend#context}
    # renders the slots half into the system prompt. This class now loads
    # neither half and threads one keyword.
    #
    # The cop's config (see .rubocop.yml) is a reasoned policy, not a number
    # to raise: a long assembler is fine, a SECOND responsibility hiding in it
    # is not. So spend the headroom the same way -- {CompactionMount},
    # {Command::Surface}, and {ToolsetBuild} are the shape to copy -- and when
    # it runs out again, extract rather than loosen.
    class Wiring
      attr_reader :ask_human, :questions, :notifier, :supervisor, :conductor, :command_surface

      # Both are the {ToolsetBuild}'s discoveries, not this object's state --
      # kept as Wiring accessors because the Repl and the exe read them here.
      delegate :role_spawn, :auto_surface, to: :toolset_build

      # The parked-approval queue, nil under --yolo -- the {Switchboard}'s now,
      # kept as a Wiring accessor because the Repl and exe read it here.
      def approvals = @switchboard&.approvals

      # The frozen {Command::Env} the run's {Command::Surface} assembled once.
      def command_env = @command_surface.env

      # `tty_factory:`/`conductor_opener:` are #run's construction seams (T9,
      # from the T1 panel note): the exe takes the real defaults; a spec hands
      # in a StringIO-backed TTY factory or a recording opener and drives #run
      # itself -- no send(:build_repl), no instance_variable_set.
      # `run_clock:` is the RUN's clock, built by {ChatLaunch} beside the
      # StatusFeed that publishes its readings and passed straight through to
      # the Conductor, which is the one place a user prompt is answered (T7).
      def initialize(options:, chronicle:, status_feed:, run_clock: Lain::RunClock.new,
                     tty_factory: Lain::Frontend::TTY.public_method(:new),
                     conductor_opener: Lain::CLI::Conductor.public_method(:open))
        @options = options
        @chronicle = chronicle
        @status_feed = status_feed
        @run_clock = run_clock
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
        agent = wire_agent(channel:, recorder:, session:, backend:, resumed:, views: nvim)
        resumed&.notices&.each(&notice)
        tty = @tty_factory.call(channel:, prompt_renderer: prompt_renderer(agent, notice))
        @conductor = open_conductor(tty)
        @conductor.guard do
          build_repl(tty:, agent:, backend:).run(nvim:, store: agent.timeline.store, session:,
                                                 first_prompt: @options[:prompt])
        end
      end

      # The run's shutdown coordinator. `run_clock:` is the T7 thread: the
      # Conductor is the ONE place a user prompt is answered, so it is where
      # {RunClock#record_input} is called -- and the clock it records on has to
      # be the instance the StatusFeed publishes, or the published `idle` never
      # resets. This class only passes on what {ChatLaunch} built.
      def open_conductor(tty)
        @conductor_opener.call(tty:, chronicle:, grace: @options[:grace], supervisor:, run_clock:)
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

      def wire_agent(channel:, recorder:, session:, backend:, resumed: nil, views: nil)
        agent = nil
        parent = -> { agent.timeline }
        @notifier = Lain::Notify.for
        # OM-6: the reactor above the Agent that un-refuses model-dispatched
        # actors. Journals a bounded drain's timeout to the live Channel; the exe
        # #run_chat below runs it under a chat-level reactor that outlives asks.
        @supervisor = Lain::Supervisor.new(journal: channel, isolation: fleet_isolation(channel))
        @ask_human = notifying_ask_human(parent)
        toolset = build_toolset(recorder, backend:, parent:, journal: channel, ask_human: @ask_human)
        chronicle.start(context: backend.context, toolset:, **resume_start(resumed))
        build_agent(toolset:, channel:, session:, backend:, timeline: resumed&.timeline, views:)
      end

      private

      attr_reader :options, :chronicle, :run_clock

      # D2: `--isolation`, read at its construction site (the --auto-approve
      # pattern) and resolved into the backend each ADOPTION leases a WorkerEnv
      # from. Only actor-mode subagents lease: #run_state builds the main chat's
      # Session on {WorkerEnv.default} deliberately, because the user's own edits
      # belong in the user's own tree. Resolved HERE, before the chronicle pins
      # its header, so an unrecognized name refuses while the session record is
      # still empty -- the refusal-before-journal ordering --resume already
      # keeps. The journal is the run's live Channel, so what comes back is
      # always {Isolation::Journal}-wrapped ({IsolationBackend}'s by-need
      # decoration), never a bare backend.
      #
      # `root:` is passed EXPLICITLY even though `Dir.pwd` is its default. It is
      # what `.lain/services.rb` is read from and where the repository search
      # starts, so it is a real dependency of this wiring, not a detail of the
      # resolver's signature -- and the day a project-root flag lands, this call
      # is where it has to be threaded. Silently inheriting the default would
      # make that omission invisible.
      def fleet_isolation(journal) = IsolationBackend.resolve(options[:isolation], root: Dir.pwd, journal:)

      # T13: the prompt's state reader is assembled HERE because this is the
      # only object holding the live Agent, the run's RunClock and the
      # StatusFeed at once -- the three things a prompt format writes against.
      # A malformed config reports through the SAME startup-notice seam a
      # resumed chat's notices use, which is why the block is threaded down;
      # `#run` takes it optionally, so SILENT stands in when nobody passed one.
      def prompt_renderer(agent, notice)
        state = Frontend::PromptComposer::RunState.new(agent:, clock: run_clock, status_feed: @status_feed)
        Frontend::PromptComposer.renderer(state:, notify: notice || Frontend::PromptComposer::SILENT)
      end

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

      # The run's capability set and the child seams hung off it: what a chat
      # can DO, and what a child inherits, is {ToolsetBuild}'s question, not
      # this assembler's (see its class comment for the parameter-triple tell
      # that named it). Held, not just called, because #role_spawn and
      # #auto_surface delegate to what the build discovered.
      attr_reader :toolset_build

      def build_toolset(recorder, backend:, parent:, journal:, ask_human:)
        @toolset_build = ToolsetBuild.new(backend:, provider: spooled_provider(backend), chronicle:, options:,
                                          supervisor: @supervisor, parent:, journal:, library: backend.library)
        @toolset_build.build(recorder, ask_human:)
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
      # `views:` is T1's: a streamed tool's bytes are a view, not a record, so
      # the executor writes them to the TTY Channel AND the editor's -- never
      # to the journal, which already holds them in the turn's tool_result.
      def build_agent(toolset:, channel:, session:, backend:, timeline: nil, views: nil)
        board = switchboard(backend)
        gate = board.gate(inner: Lain::Effect::Handler::Live.new(toolset:,
                                                                 channel: LiveViews.tool_output(channel, views)))

        agent = nil
        Lain::Agent.new(toolset:, context: board.graft(backend.context), handler: gate, session:, timeline:,
                        request_override: Lain::Agent::RequestOverride.new, # T18: ResendBridge's slot
                        tool_middleware: ToolGuard.stack(chronicle),
                        turn_middleware: chronicle.turn_middleware(-> { agent.timeline }),
                        **agent_backing(backend, channel)).tap { |built| agent = built }
      end

      # A8: the provider, and the compaction wiring hung off it -- the per-turn
      # Context source, the eager-summary observer, and the journal tee that
      # feeds the source the cache-read counts the render seam cannot see
      # ({CompactionMount}). One method, because the mount must reference THE
      # ONE provider the run talks to: {Compaction::Cold} compares idle time
      # against that provider's own cache TTL, so a second construction would
      # be a second answer, and the pairing cannot be allowed to come apart.
      #
      # The mount is deliberately NOT memoized. Every piece of run state it
      # hands over -- the Source's accumulated warmth, the Eager's fired
      # summaries -- is memoized in {Backend}, which is loud about a differing
      # rebind ({Backend::Rebound}); the mount itself is a pure assembler over
      # those, so a memo here would only add a second place for a stale
      # collaborator to hide.
      def agent_backing(backend, channel)
        provider = spooled_provider(backend, channel:)
        { provider:, **CompactionMount.new(backend:, provider:, chronicle:, channel:).agent_kwargs }
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
      # middleware, the run's one skill library -- is {Command::Surface}'s (T9).
      def build_repl(tty:, agent:, backend:)
        @replies = HumanReplies.new(tty:, conductor: @conductor, ask_human:, questions:)
        @command_surface = assemble_surface(agent:, library: backend.library, tty:)
        Repl.new(agent:, tty:, replies: @replies, chronicle: @chronicle, conductor: @conductor, approvals:, notifier:,
                 supervisor:, middleware: @command_surface.middleware, commands: @command_surface.commands,
                 auto_surface:, goal_driver:)
      end

      # The surface assembly, its own method because T15's ABC trip said so when
      # it threaded the run's catalog and slots through here -- which the T40
      # panel read as silencing the cop rather than answering it. Naming the pair
      # MOVED that number without clearing it, and the measurements are worth
      # keeping because the next reader will otherwise re-derive them: this
      # method fell 8 -> 6, and build_repl inlined measures 18.11 against a limit
      # of 17 (17.12 with the Repl's two surface kwargs folded into one splat).
      #
      # What holds it over is a DIFFERENT unnamed object, and the arithmetic says
      # so plainly: `approvals`, `goal_driver` and `supervisor` are each read
      # TWICE in the inlined body, once for the Surface and once for the Repl,
      # because both are built from the same six collaborators this class holds.
      # That is the repeated parameter list that named {ToolsetBuild} and named
      # the library, showing up a third time. Naming it is what would finally let
      # this method go, and it is written down as a card rather than left in a
      # comment -- see the follow-ups in
      # planning/specs/chunk-review-missing-objects.md. Do NOT clear the number by
      # hoisting the three duplicate reads into locals: that measures 15.81 and
      # passes the cop by bending the method to the limit, which is this
      # comment's whole complaint, one layer down.
      def assemble_surface(agent:, library:, tty:)
        Command::Surface.new(agent:, replies: @replies, supervisor:, role_spawn:, approvals:, goal_driver:, library:,
                             chronicle: @chronicle, status_feed: @status_feed,
                             **@switchboard.surface_kwargs(conductor: @conductor, tty:))
      end

      # The T21 standing-goal driver (memoized, so the surface and the Repl poll
      # ONE instance), over the session's live journal -- the null device under
      # --no-journal, the same resolution the Switchboard uses.
      def goal_driver = @goal_driver ||= GoalDriver.new(journal: goal_journal, quiescent: -> { quiescent? })

      # Resolved INSIDE the memo, not above it: the fallback OPENS /dev/null,
      # so hoisting it out (as this did until T15's review caught it) leaks one
      # File per extra #goal_driver call -- opened, discarded unread, never
      # closed. Two readers poll the driver, so that was a real leak, not a
      # hypothetical one.
      def goal_journal = chronicle.telemetry_kwargs.fetch(:journal) { Journal.new(io: File.open(File::NULL, "ab")) }

      # Both OBSERVABLE halves of "do not drive while the fleet is unquiet": a
      # parked approval, and a human question waiting for an answer. The inbox
      # half reads HumanReplies#pending? (built in build_repl before the driver,
      # so @replies is set by the time a poll can run) -- the T21 review's owed
      # completion of the escalated seam, no longer a follow-up.
      def quiescent?
        (approvals.nil? || approvals.each.all?(&:decided?)) && !@replies.pending?
      end
    end
  end
end
