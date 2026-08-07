# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

require_relative "wiring/agent_build"
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
    # ⚠️ THIS CLASS LIVES AGAINST A 110-LINE Metrics/ClassLength BUDGET. Measure
    # it (`rubocop --only Metrics/ClassLength`, with the Max forced low enough to
    # make it report) rather than trusting a number written here; three of the
    # four times it has been read it was in single-digit headroom, which is not
    # room for a feature: EXTRACT FIRST.
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
    # T27 was the third time and spent the last of it. "Which epic is this chat
    # in, and who holds the baton for its documents" is {EpicMount}'s question,
    # not this one's, and the tell was the tell again: the
    # `(home:, review:, notes:)` triple {Lain::Tools::RequestReview} takes, three
    # collaborators that travel together AND carry an invariant between them.
    # What is left here is one keyword at one call site. That left no room for a
    # fourth, so T4 was the extraction the previous edition of this comment
    # demanded of whatever card came next -- and, unlike the three above, it was
    # spent on nothing: it added no feature and moved {AgentBuild} out. Its tell
    # was a different one, worth naming because the next reader will meet it
    # rather than the parameter triple: the Agent, the provider it talks to,
    # that provider's compaction mount and the instrumentation over it are ONE
    # subject with no share in "who are this chat's collaborators", and they had
    # simply accumulated here.
    #
    # The board is what could not go with them, and {AgentBuild}'s own comment
    # is where that is written down -- not repeated here, because it is a fact
    # about the extracted module rather than about this list.
    #
    # T5 is what T4's headroom was made for, and it spent six of the fourteen
    # lines: the run's {Lain::Project} arrives as one keyword and replaces the
    # five independent `Dir.pwd` reads that used to answer "where is this
    # project" five times. It also spent the last of #build_toolset's AbcSize
    # budget, which is why {#epic_mount} is a method now -- the same rule, at
    # a different cop.
    #
    # The cop's config (see .rubocop.yml) is a reasoned policy, not a number
    # to raise: a long assembler is fine, a SECOND responsibility hiding in it
    # is not. So spend the headroom the same way -- {CompactionMount},
    # {Command::Surface}, {ToolsetBuild} and {EpicMount} are the shape to copy --
    # and when it runs out again, extract rather than loosen.
    class Wiring
      # Who may ask the human, and where an arrival goes. One object because
      # the three are one fact: an asker that announces to a queue nobody
      # registered can be answered by nobody, and a registration without the
      # announcement is an agent parked in silence.
      #
      # It is a SECOND responsibility rather than more of this class's own --
      # "assemble a chat" does not include "route an answer back to whoever
      # asked" -- and {Wiring} had one line of ClassLength headroom, so the
      # rule the class comment states applied: extract, do not grow. Nested
      # rather than a file of its own because T11 scopes the CLI half of the
      # question chunk to this file, the reason {Frontend::TTY::Inbox} is
      # nested in tty.rb.
      class Askers
        # An asker and the thing that stops it being routable. Both, because
        # retention in the {Tools::AskHuman::Directory} runs from `register`
        # to `deregister` and NOTHING else releases it: whoever owns an
        # asker's lifetime has to hold the registration, which the run's own
        # asker never needs (it dies with the run) and a child's lease does.
        Enrolled = Data.define(:asker, :registration)

        # What a desktop notification may spend on WHO is asking: dunstify
        # renders `"#{agent} asks"` as the title, and an asker's identity in
        # the record is a 71-character correlation digest -- not a title. The
        # same 19 the TTY drain and {Frontend::Neovim::InboxView} already clamp
        # their sender column to, so the three surfaces name an asker the same
        # way.
        NAME_WIDTH = 19

        attr_reader :questions, :directory

        # The seam wired to nothing: its arrivals reach a queue nobody drains
        # and a desktop that is not there, and its directory routes only its
        # own askers. It exists for the direct-construction seams the specs
        # drive -- {ToolsetBuild::NoSwitchboard}'s precedent, one class over --
        # and it is NOT a sanctioned production state: a child enrolled here
        # parks a human question nobody can see, which is the exact failure the
        # arrival seam exists to prevent. The exe always passes the run's own.
        def self.unwired
          new(notifier: Lain::Notify::Null.new, observer: Lain::Event::ChainWriter::Null.new)
        end

        # @param notifier [Lain::Notify] the desktop half of an arrival
        # @param observer [#call] the chronicle's -- Q and A are exactly the
        #   events a Timeline walk can never find, so a missing observer is
        #   silent record loss; required for that reason, not defaulted.
        def initialize(notifier:, observer:)
          @notifier = notifier
          @observer = observer
          @questions = Async::Queue.new
          @directory = Lain::Tools::AskHuman::Directory.new
        end

        # One agent's asker: announced to the human on every ask, and
        # registered so an answer NAMING one of its sets routes back to it.
        # Both locals are read inside the notify thunk at CALL time -- the
        # late-binding idiom this file uses twice more -- so the tool, the
        # names it opens, and the announcement it fans out cannot come apart.
        #
        # `registration` is declared before the thunk that reads it because
        # the two cannot be built in one order: the registration needs the
        # asker, and the asker's announcement needs the registration. A name
        # first mentioned INSIDE the block parses as a method call and raises
        # there instead, which is the whole reason the nil is written out.
        #
        # @param parent [Timeline, #call] the live parent-Timeline handle ({AskHuman}'s
        #   own `parent:`) -- a Timeline or a thunk reading one, since the toolset is
        #   built before the Agent; the shared Store and the asker's identity both
        #   ride on it
        # @param agent [String, nil] what a human is told is asking, when this
        #   asker has a name worth reading (the main chat's, a child's role).
        #   Per-asker, never per-seam: one name for every arrival is the
        #   hardcoded `"lain"` this widening removed. Absent, the correlation
        #   stands in, clamped -- see {#desktop_name}.
        #
        #   It is handed to the ASKER as well as to the announcement (T15), so
        #   it rides the Q event ({Tools::AskHuman::ASKED_BY}) and the surfaces
        #   that never see an arrival -- {Frontend::Neovim::InboxView} folds the
        #   record stream -- name the asker the same way this one does.
        def enrol(parent, agent: nil)
          registration = nil
          asker = Lain::Tools::AskHuman::Notifying.new(
            parent:, observer: @observer, agent:,
            notify: ->(question) { announce(question, asker:, registration:, agent:) }
          )
          registration = @directory.register(asker)
          Enrolled.new(asker:, registration:)
        end

        private

        # I5, widened (T11): ONE arrival, three surfaces. What rides the queue
        # is the inbox item itself, not the question's bytes -- the digest an
        # answer must cite, and the asker that asked it -- and both are read
        # HERE, at the instant the Q event was written, because that is the
        # only instant they are true. Read at drain time instead, "who asked"
        # is whoever asked most recently and the digest is not recoverable at
        # all.
        #
        # The name is opened on the registration BEFORE the arrival goes out,
        # and that ordering is the whole of the routing: {Directory} answers
        # only names some registration has heard of, so a question announced
        # to a human who could then answer it faster than it was registered
        # would be refused as unknown.
        def announce(question, asker:, registration:, agent:)
          item = HumanReplies::InboxItem.asked(question, asker.last_question, agent:)
          registration.asked(item.digest)
          @questions.enqueue(item)
          @notifier.question(agent: desktop_name(agent, item), text: question)
        end

        # Who the desktop is told is asking: this asker's own name when it has
        # one, else the correlation that identifies it everywhere else. Both
        # arms clamp, and they clamp in ONE place, so the bound holds for a
        # name nobody thought to keep short as much as for a digest.
        def desktop_name(agent, item)
          (Blankness.blank?(agent) ? item.from.to_s : agent.to_s)[0, NAME_WIDTH]
        end
      end

      # What a human is told is asking when the question came from the chat
      # they are having, rather than from something it spawned. Named here and
      # not in {Askers} because it is a fact about THIS agent -- a child passes
      # its own role, and a seam-wide default would be the hardcoded name the
      # arrival widening removed.
      MAIN_AGENT = "lain"

      attr_reader :ask_human, :askers, :notifier, :supervisor, :conductor, :command_surface, :project

      # Both are the {ToolsetBuild}'s discoveries, not this object's state --
      # kept as Wiring accessors because the Repl and the exe read them here.
      delegate :role_spawn, :auto_surface, to: :toolset_build

      # The arrival queue the Repl's replier parks on, and the routing table an
      # answer names its set through -- {Askers}' now, read here because the
      # Repl and the exe read them here.
      delegate :questions, :directory, to: :askers

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
      #
      # Every argument is tagged because ONE of them had to be: `@option` is what
      # yard-lint wants beside an options hash, and rubocop-yard then demands a
      # `@param` for each remaining argument. `@option` last, after every
      # `@param`, is the order yard-lint fixes.
      #
      # @param options [Hash] the parsed CLI options
      # @param chronicle [Chronicle] the run's session file and its journal
      # @param status_feed [StatusFeed] what the tmux HUD reads
      # @param run_clock [RunClock] the RUN's clock, built by {ChatLaunch}
      # @param project [Project] where this run's writes belong and where it is
      #   being run FROM -- {ChatLaunch} resolves it once and passes it here, so
      #   the five collaborators below take one answer rather than each asking
      #   `Dir.pwd` its own version of the question
      # @param tty_factory [#call] #run's TTY seam; a spec hands in a StringIO-backed one
      # @param conductor_opener [#call] #run's Conductor seam
      # @option options [String] :prompt the first question, seeded from --prompt
      # @option options [Numeric] :grace seconds a first Ctrl-C grants a run
      # @option options [String] :isolation the backend a fleet leases workers from
      def initialize(options:, chronicle:, status_feed:, run_clock: Lain::RunClock.new,
                     project: Project::Resolver.default_project,
                     tty_factory: Lain::Frontend::TTY.public_method(:new),
                     conductor_opener: Lain::CLI::Conductor.public_method(:open))
        @options = options
        @chronicle = chronicle
        @status_feed = status_feed
        @run_clock = run_clock
        @project = project
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
        agent = wire_agent(channel:, recorder:, session:, backend:, resumed:, views: nvim, notice:)
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
        session = resumed ? resumed.session : Lain::Session.new(memory: recorder, worker_env: chat_env)
        chronicle.wrap_memory(recorder)
        [recorder, chronicle.wrap_session(session)]
      end

      # The main chat's host-side context: {WorkerEnv.default}'s environment
      # snapshot, at the PROJECT's cwd. Still not a leased environment -- the
      # comment on #fleet_isolation is unchanged and still the reason -- the
      # user's own edits still land in the user's own tree; the tree is now
      # named by the resolved Project rather than by whatever `Dir.pwd` was when
      # the default was computed. The two agree whenever a chat is started from
      # its own root, which is why this is byte-identical for the ordinary run.
      def chat_env = Lain::WorkerEnv.default.with(cwd: project.cwd)

      def wire_agent(channel:, recorder:, session:, backend:, resumed: nil, views: nil, notice: nil)
        agent = nil
        parent = -> { agent.timeline }
        # `desktop:` is CONSENT and it is never inferred: `Notify.for` used to
        # read dunstify-on-PATH as permission, so every spec and probe reaching
        # this line notified the human running the machine (2026-08-05, nine of
        # them). --desktop defaults ON in exe/lain, so an interactive chat is
        # unchanged; a directly-constructed Wiring passes no such option and gets
        # the Null. Pinned by spec/desktop_discipline_spec.rb.
        @notifier = Lain::Notify.for(desktop: options[:desktop])
        # OM-6: the reactor above the Agent that un-refuses model-dispatched
        # actors. Journals a bounded drain's timeout to the live Channel; the exe
        # #run_chat below runs it under a chat-level reactor that outlives asks.
        @supervisor = Lain::Supervisor.new(journal: channel, isolation: fleet_isolation(channel))
        @ask_human = wire_askers(parent)
        toolset = build_toolset(recorder, backend:, parent:, journal: channel, ask_human: @ask_human, notice:)
        chronicle.start(context: backend.context, toolset:, **resume_start(resumed))
        # ASSIGNED, not merely returned: `parent` above closes over this local,
        # and the tools built between here and there read it at CALL time. Left
        # as a bare return expression the local stays nil forever -- the caller's
        # `agent = wire_agent(...)` binds a different local in a different scope
        # -- so the first ask_human question and the first subagent spawn both
        # raise NoMethodError on nil.
        agent = build_agent(toolset:, channel:, session:, backend:, timeline: resumed&.timeline, views:, notice:)
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
      # `root:` is passed EXPLICITLY, and it is the {Project}'s -- not `Dir.pwd`,
      # which is what the previous edition of this comment predicted would have
      # to change "the day a project-root flag lands". It is what
      # `.lain/services.rb` is read from and where the repository search starts,
      # so a run from a subdirectory declares the services its PROJECT declares.
      def fleet_isolation(journal) = IsolationBackend.resolve(options[:isolation], root: project.root, journal:)

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

      # The run's ask-the-human seam, and the parent agent's own asker off it.
      # The registration that comes back is dropped ON PURPOSE: this asker is
      # routable for exactly as long as the run, and the {Askers} directory
      # holds it. A CHILD's is the one that must be kept and deregistered on
      # the lease that reaps it -- {Askers::Enrolled} is where that card reads
      # both halves.
      def wire_askers(parent)
        @askers = Askers.new(notifier: @notifier, observer: chronicle.observer)
        @askers.enrol(parent, agent: MAIN_AGENT).asker
      end

      # The run's capability set and the child seams hung off it: what a chat
      # can DO, and what a child inherits, is {ToolsetBuild}'s question, not
      # this assembler's (see its class comment for the parameter-triple tell
      # that named it). Held, not just called, because #role_spawn and
      # #auto_surface delegate to what the build discovered.
      attr_reader :toolset_build

      # `epic:` is WHICH epic this chat is in and the review baton over it --
      # {EpicMount}, or its NoEpic when none resolves, which is why nothing here
      # or in the build asks whether there is one. It stood at this call site
      # until T5, on the measured ground that the class was two lines under its
      # ClassLength budget and a named method would buy nothing; T5 threaded the
      # project ROOT into it and into the review seams, which put #build_toolset
      # over Metrics/AbcSize, so it is #epic_mount below now. The rule the class
      # comment states applied, one cop over: extract, do not loosen.
      #
      # `bindings:` is the same late-binding the `parent` thunk above uses, for a
      # sharper reason: {HumanReplies} is built in #build_repl, strictly AFTER
      # this, so the tool reads the thunk at CALL time. It closes over an IVAR
      # rather than a local, which is what makes it actually late -- see the T27
      # hand-back for the sibling thunk that captures a local and stays nil.
      # `notice:` is DEFAULTED where `epic:` upstream is required, and the two
      # are not the same kind of argument: forgetting the startup seam loses a
      # sentence, where forgetting the epic would lose the tool. #run takes its
      # own notice block optionally for the same reason.
      #
      # `askers:` is the run's ONE ask-the-human seam, threaded here for the
      # same reason `provider:` is: a child that asks the human must announce
      # onto the queue the human is already draining and register in the
      # directory their answer is routed through, and a second one built down
      # there would be a second answer to "who is holding this question". It is
      # the whole of what a child spawn needs -- {Askers#enrol} hands back both
      # the asker and the registration that releases it -- so nothing else
      # about this seam crosses into the child path.
      def build_toolset(recorder, backend:, parent:, journal:, ask_human:, notice: nil)
        @toolset_build = ToolsetBuild.new(backend:, provider: AgentBuild.spooled_provider(backend, chronicle:),
                                          chronicle:, options:,
                                          supervisor: @supervisor, parent:, journal:, library: backend.library,
                                          switchboard: -> { @switchboard }, askers: @askers,
                                          epic: epic_mount(notice))
        @toolset_build.build(recorder, ask_human:)
      end

      # The chat's epic and the review baton over it, over the PROJECT's root --
      # so a chat started in `services/ingest` mounts the epic its project
      # declares and reviews the repository that project is, rather than
      # whichever of the two the working directory happened to name.
      def epic_mount(notice)
        EpicMount.for(chronicle:, options:, notice:, notify: @notifier, root: project.root,
                      bindings: replies, **ReviewSeams.for(replies, root: project.root))
      end

      # The run's ONE live {HumanReplies}, late. Every seam that needs it takes
      # this same thunk: it is built in #build_repl, strictly AFTER the toolset,
      # so the review tool, the surface a changeset is drawn on and the view its
      # gestures resolve through all read it at CALL time. It closes over an
      # IVAR rather than a local, which is what makes it actually late -- see the
      # T27 hand-back for the sibling thunk that captured a local and stayed nil.
      #
      # T31a: `**ReviewSeams.for` above is what turned the changeset half of
      # `request_review` on. This mount passed `notify:` and `bindings:` only, so
      # `changesets:` and `surface:` stayed nil, `Implementation#hold` answered
      # `Refusals.no_changeset` on every call in every real process, and the
      # surface resolved to the Null -- while {EpicMount}'s own comment said the
      # seam was threaded rather than absent precisely so a caller which CAN
      # answer would inject one. None ever did, and nothing among 10865 examples
      # could see it.
      def replies = -> { @replies }

      # The Agent and everything hung off the provider it talks to is
      # {AgentBuild}'s question now, not this assembler's. This method survives
      # the extraction because it still does the one piece of work that could
      # not move: `switchboard(backend, toolset)` is the ONLY call to
      # #switchboard, so the memo three later readers depend on is assigned
      # here or nowhere. {AgentBuild}'s comment carries the why.
      def build_agent(toolset:, channel:, session:, backend:, timeline: nil, views: nil, notice: nil)
        AgentBuild.build(board: switchboard(backend, toolset, notice), chronicle:, channel:, session:, backend:,
                         timeline:, views:)
      end

      # I4/T14: the {Switchboard} owns Gate's policy now -- the queue (or
      # ApproveAll under --yolo) behind the ONE PolicySwitch /yolo flips; Gate
      # itself stays construction-fixed. It resolves its own journal from the
      # chronicle (the null device under --no-journal). Memoized where
      # build_agent first needs it, so the direct build_agent seam the specs
      # drive assembles it too.
      #
      # T10: it owns the run's CAPABILITY set on the same terms. `toolset:` is
      # the BASE set every posture resolves from -- attenuation is monotone, so
      # leaving `plan` has to rebuild from what the session was built with and
      # never from what the previous posture left behind -- and what comes back
      # as `board.toolset` is the live slot the Agent and its executor hold, so
      # a `/mode` flip changes the rendered schema without rebuilding either.
      def switchboard(backend, toolset, notice = nil)
        @switchboard ||= Switchboard.for(chronicle:, options:, model: backend.context.model, toolset:,
                                         rules: Project::Consent.for(project:, notice:).rules)
      end

      # The Repl over the run's collaborators -- the accessors are this class's
      # own seams ({Askers} wired the queue and the routing table the toolset's
      # asker announces through), so the Repl reads them here rather than
      # through exe-instance state. What the drain is handed is the DIRECTORY,
      # not the run's one asker: "which asker holds the set this answer names"
      # is a question only the directory can answer, and asking the parent's
      # asker instead is how a child's question becomes unanswerable (T11). The
      # {HumanReplies} drain is built HERE (not inside Repl) so the Env's
      # replies reader and the Repl's collaborator are one object; everything a
      # typed line dispatches through -- command registry, frozen Env, skill
      # middleware, the run's one skill library -- is {Command::Surface}'s (T9).
      def build_repl(tty:, agent:, backend:)
        @replies = HumanReplies.new(tty:, conductor: @conductor, ask_human: directory, questions:)
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
                             chronicle: @chronicle, status_feed: @status_feed, root: project.root,
                             **@switchboard.surface_kwargs(conductor: @conductor, tty:))
      end

      # The T21 standing-goal driver (memoized, so the surface and the Repl poll
      # ONE instance), over the session's live journal -- the null device under
      # --no-journal, the same resolution the Switchboard uses.
      def goal_driver = @goal_driver ||= GoalDriver.new(journal: goal_journal, quiescent: -> { quiescent? })

      # Asked INSIDE the memo, not above it: under --no-journal the answer OPENS
      # /dev/null ({Chronicle::Null#record_journal}), so hoisting this out (as it
      # was until T15's review caught it) leaks one File per extra #goal_driver
      # call -- opened, discarded unread, never closed. Two readers poll the
      # driver, so that was a real leak, not a hypothetical one.
      def goal_journal = chronicle.record_journal

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
