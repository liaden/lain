# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

require_relative "wiring/agent_build"
require_relative "wiring/askers"
require_relative "wiring/base_tools"
require_relative "wiring/board_build"
require_relative "wiring/run_state"
require_relative "wiring/toolset_build"

module Lain
  module CLI
    # The chat-assembly responsibility, lifted out of the Thor class the way Repl
    # was: a chat's Agent -- toolset, subagent, approval gate, provider spool and
    # the ask_human reply seam -- is its own job. It hands back the built Agent
    # and exposes the asker/question pair so #run_chat can give the Repl the
    # reply path this object wired.
    #
    # It lives against a 110-line `Metrics/ClassLength` budget and has spent four
    # extractions reaching it: {ToolsetBuild}, {EpicMount}, {AgentBuild}, then
    # {Askers} with {RunState}. MEASURE the headroom -- `rubocop --only
    # Metrics/ClassLength` with the Max forced low enough to report -- rather
    # than trusting a number written here; three of the four readings found
    # single-digit headroom, which is not room for a feature. The tell each time
    # was a parameter list threaded verbatim through several private methods,
    # which is an object nobody has named yet. The cop's config in .rubocop.yml
    # is a reasoned policy, not a number to raise: a long assembler is fine, a
    # second responsibility hiding in it is not.
    #
    # Measure, because the cop does not count what you expect: it DISCOUNTS a
    # nested class's body, so promoting {Askers} to its own file bought ~1 line
    # against the thirty-four it occupies in a reader's scroll. Spend the next
    # extraction on this class's OWN methods.
    #
    # Still unnamed: the object {#assemble_surface} wants. Neither obvious seam
    # takes it -- #assemble_surface cannot leave, because
    # `wiring/agent_build_spec.rb` drives it directly to assert the switchboard
    # memo is set by the time the surface is assembled; #run cannot, because it
    # orchestrates this class's own assembly steps, so an object holding it
    # would have to be handed this one, which is a god-object handle rather than
    # the {AgentBuild} shape.
    class Wiring
      # What a human is told is asking when the question came from the chat they
      # are having rather than from something it spawned. A fact about THIS
      # agent, not about the seam: a child passes its own role.
      MAIN_AGENT = "lain"

      attr_reader :ask_human, :askers, :notifier, :supervisor, :conductor, :command_surface, :project

      # {ToolsetBuild}'s discoveries, not this object's state.
      delegate :role_spawn, :auto_surface, to: :toolset_build

      # The arrival queue the Repl's replier parks on, and the routing table an
      # answer names its set through.
      delegate :questions, :directory, to: :askers

      # The parked-approval queue, nil under --non-interactive.
      def approvals = @switchboard&.approvals

      # ONE reading of `--non-interactive`, threaded to the Repl, the askers and
      # the Switchboard, so those three cannot come to disagree about whether a
      # human is there -- the way `--yolo` once did when it was read twice.
      def attended? = !options[:non_interactive]

      # "Did it finish what it was asked", as a process exit status. Complete
      # before a Repl exists: a run that refused during assembly reports through
      # the raise, not through this.
      def exit_status = @repl ? @repl.exit_status : Repl::Outcome::COMPLETED

      # The opt-in local-model triage surface for parked reads carrying
      # sensitive regions -- nil without `--secret-oracle`, so the default run
      # spawns no extra fiber.
      #
      # Nothing in this class may choose the oracle's provider:
      # {Oracle::SecretRead.tier} constructs the local ollama arm itself, and the
      # `--provider` / `--summarizer-provider` knobs held here are exactly what
      # must not reach it -- that module's header has what
      # `--summarizer-provider anthropic` would do to a candidate secret's path.
      # The journal is resolved ONCE and shared, on {#goal_journal}'s note: each
      # call OPENS a file.
      #
      # @return [Approval::SecretSurface, nil]
      def secret_surface
        return nil unless options[:secret_oracle]

        @secret_surface ||= begin
          journal = goal_journal
          Approval::SecretSurface.new(oracle: Oracle::SecretRead.tier(journal:), journal:)
        end
      end

      # The frozen {Command::Env} the run's {Command::Surface} assembled once.
      def command_env = @command_surface.env

      # The `tty_factory:` and `conductor_opener:` keywords are #run's
      # construction seams: a spec hands in a StringIO-backed TTY factory or a
      # recording opener and drives #run itself -- no send(:build_repl), no
      # instance_variable_set.
      #
      # Every argument is tagged because ONE of them had to be: yard-lint wants
      # an `@option` beside an options hash, and rubocop-yard then demands a
      # `@param` for each remaining argument, in that order.
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
      # to the frontend. The conductor slot is set BEFORE the repl blocks, so the
      # exe's ensure can close it even when the repl raises mid-run.
      def run(backend:, resumed:, nvim:, &notice)
        channel = Lain::Channel.new
        recorder, session = run_state(resumed)
        agent = wire_agent(channel:, recorder:, session:, backend:, resumed:, views: nvim, notice:)
        resumed&.notices&.each(&notice)
        tty = @tty_factory.call(channel:, prompt_renderer: prompt_renderer(agent, notice))
        @conductor = open_conductor(tty)
        @conductor.guard do
          build_repl(tty:, agent:, backend:).run(nvim:, store: bind_hud_store(agent), session:,
                                                 first_prompt: @options[:prompt])
        end
      end

      # The run's shutdown coordinator, and the one place a user prompt is
      # answered -- so it is where {RunClock#record_input} lands. The clock it
      # records on must be the instance the StatusFeed publishes, or the
      # published `idle` never resets; this class only passes on what
      # {ChatLaunch} built.
      def open_conductor(tty)
        @conductor_opener.call(tty:, chronicle:, grace: @options[:grace], supervisor:, run_clock:)
      end

      # The recorder and the journaled Session, fresh or resumed -- {RunState}'s
      # question, and its invariant is written there. A method rather than an
      # inline at its one caller because it is PUBLIC surface: four spec files
      # drive `wiring.run_state(nil)` to get a real recorder and session to build
      # an assembly against.
      def run_state(resumed) = RunState.for(resumed:, chronicle:, worker_env: chat_env)

      # The main chat's host-side context, at the PROJECT's cwd rather than at
      # whatever `Dir.pwd` was when the default was computed. Deliberately not a
      # leased environment -- see #fleet_isolation: the user's own edits belong
      # in the user's own tree.
      def chat_env = Lain::WorkerEnv.default.with(cwd: project.cwd)

      def wire_agent(channel:, recorder:, session:, backend:, resumed: nil, views: nil, notice: nil)
        parent = -> { @agent.timeline }
        # Desktop notification is CONSENT and is never inferred: `Notify.for`
        # once read dunstify-on-PATH as permission, so every spec and probe
        # reaching this line notified the human running the machine (nine of
        # them, 2026-08-05). Pinned by spec/desktop_discipline_spec.rb.
        #
        # Journalling to the run's own Channel is what makes the fault guard
        # WITNESSED rather than merely present: a surface fiber that dies inside
        # its sweep silently stops notifying for the rest of the session, so a
        # guard journalled into the Null would leave a bench with no evidence it
        # fired.
        @notifier = Lain::Notify.for(desktop: options[:desktop], journal: channel)
        # The reactor above the Agent that un-refuses model-dispatched actors.
        # The exe runs it under a chat-level reactor that outlives asks.
        @supervisor = Lain::Supervisor.new(journal: channel, isolation: fleet_isolation(channel))
        @ask_human = wire_askers(parent)
        toolset = build_toolset(recorder, backend:, parent:, journal: channel, ask_human: @ask_human, notice:)
        # Resolved BEFORE the record opens, and the statement order IS the
        # guarantee -- see #switchboard for what can refuse here and why a
        # refusal must land ahead of the header.
        switchboard(backend, toolset, notice)
        chronicle.start(context: backend.context, toolset:, **resume_start(resumed))
        # ASSIGNED to an ivar, not merely returned: the `parent` thunk above and
        # the usage thunk #build_toolset passes both read this slot at CALL time.
        # Left as a bare return expression it stays nil forever -- the caller's
        # local is a different scope -- so the first ask_human question, the
        # first subagent spawn and the first session_usage call all raise
        # NoMethodError on nil.
        #
        # ONE agent per Wiring, and the slot is why that must stay true. Calling
        # #wire_agent twice on the same instance RETARGETS the first agent's
        # thunks at the second, so agent one answers with agent two's Timeline
        # and tokens: not a crash, a silently wrong number -- the exact failure
        # `session_usage` exists to remove. The `agent = nil` local this replaced
        # kept two calls apart by accident of scoping; the slot does not, and no
        # caller relies on it. The guard is one `raise unless @agent.nil?` here,
        # which holds ClassLength but puts this method over Metrics/AbcSize, so
        # it is owed together with the extraction this class asks for -- whoever
        # pays that debt must bring the guard with it.
        @agent = build_agent(toolset:, channel:, session:, backend:, resumed:, views:, notice:)
      end

      private

      attr_reader :options, :chronicle, :run_clock

      # The first line at which the run HAS a Store, so it is where the HUD's
      # feed is given one: {ChatLaunch} builds that feed before Wiring exists,
      # and until it is bound its inbox_count retires nothing and only climbs.
      #
      # Named for the BINDING rather than the value, and private, because it is a
      # command that happens to answer -- a query name would hide the write.
      def bind_hud_store(agent) = agent.timeline.store.tap { |store| @status_feed.bind_store(store) }

      # The backend each ADOPTION leases a WorkerEnv from. Only actor-mode
      # subagents lease; the main chat's Session is built on {WorkerEnv.default}
      # deliberately, because the user's own edits belong in the user's own tree.
      #
      # Resolved HERE, before the chronicle pins its header, so an unrecognized
      # name refuses while the session record is still empty -- the
      # refusal-before-journal ordering --resume already keeps.
      #
      # The root is the {Project}'s, not `Dir.pwd`: it is what
      # `.lain/services.rb` is read from and where the repository search starts,
      # so a run from a subdirectory declares the services its PROJECT
      # declares.
      def fleet_isolation(journal) = IsolationBackend.resolve(options[:isolation], root: project.root, journal:)

      # Assembled HERE because this is the only object holding the live Agent,
      # the run's RunClock and the StatusFeed at once -- the three things a
      # prompt format writes against. A malformed config reports through the same
      # startup-notice seam a resumed chat's notices use, which is why the block
      # is threaded down.
      def prompt_renderer(agent, notice)
        state = Frontend::PromptComposer::RunState.new(agent:, clock: run_clock, status_feed: @status_feed)
        Frontend::PromptComposer.renderer(state:, notify: notice || Frontend::PromptComposer::SILENT)
      end

      # {AgentBuild}'s question, not this assembler's. The method survives the
      # extraction because it is the seam `spec/lain/cli_spec.rb` drives -- which
      # is also what pins `session:` as required, so a defaulted fresh Session
      # cannot silently mis-wire memory. It takes the resume RESULT rather than a
      # `timeline:` lifted off it: reading `resumed&.timeline` at the caller cost
      # #wire_agent the one branch that put it over AbcSize.
      def build_agent(toolset:, channel:, session:, backend:, resumed: nil, views: nil, notice: nil)
        AgentBuild.build(board: switchboard(backend, toolset, notice), chronicle:, channel:, session:, backend:,
                         timeline: resumed&.timeline, views:)
      end

      # A resumed chat opens its NEW journal chained to the old one. Derived from
      # the Resume result so the exe never assembles the wire-format hashes.
      def resume_start(resumed) = resumed ? { resumed_from: resumed.resumed_from, written: resumed.written } : {}

      # The run's ask-the-human seam, and the parent agent's own asker off it.
      # The registration that comes back is dropped ON PURPOSE: this asker is
      # routable for exactly as long as the run. A CHILD's must be kept and
      # deregistered on the lease that reaps it -- see {Askers::Enrolled}.
      def wire_askers(parent)
        @askers = Askers.new(notifier: @notifier, observer: chronicle.observer, attended: attended?)
        @askers.enrol(parent, agent: MAIN_AGENT).asker
      end

      # What a chat can DO and what a child inherits is {ToolsetBuild}'s
      # question. Held, not just called, because #role_spawn and #auto_surface
      # delegate to what the build discovered.
      attr_reader :toolset_build

      # The epic mount resolves to {EpicMount} or its NoEpic, which is why
      # nothing here or in the build asks whether there is one. The bindings
      # thunk is late for a sharper reason than the `parent` one above:
      # {HumanReplies} is built in #build_repl, strictly AFTER this, so the tool
      # reads the thunk at CALL time -- and it closes over an IVAR rather than a
      # local, which is what makes it actually late.
      #
      # The askers seam is the run's ONE ask-the-human seam. A child that asks
      # must announce onto the queue the human is already draining and register
      # in the directory their answer is routed through; a second one built down
      # there would be a second answer to "who is holding this question".
      #
      # The root is the PROJECT's, and here that is sharper than elsewhere:
      # {ToolsetBuild} resolves `--exec` from it and a container MOUNTS what that
      # resolves, so `Dir.pwd` would mount whichever subdirectory the shell
      # happened to be in, leaving every path above it missing INSIDE the
      # container while it still resolves outside one.
      #
      # The usage thunk's `&.` is NOT a coalesce: it lets the thunk RETURN nil so
      # {Lain::Tools::SessionUsage}'s own `|| raise(Unwired)` fires and the model
      # sees an intelligible sentence instead of `undefined method 'usage' for
      # nil`. Nothing is invented either way -- `Lain::Usage.zero` is truthy, so
      # a run that has spent nothing still reports zero and cannot be confused
      # with an unassigned slot.
      def build_toolset(recorder, backend:, parent:, journal:, ask_human:, notice: nil)
        @toolset_build = ToolsetBuild.new(backend:, provider: AgentBuild.spooled_provider(backend, chronicle:),
                                          chronicle:, options:, root: project.root, usage: -> { @agent&.usage },
                                          supervisor: @supervisor, parent:, journal:, library: backend.library,
                                          switchboard: -> { @switchboard }, askers: @askers,
                                          epic: epic_mount(notice))
        @toolset_build.build(recorder, ask_human:)
      end

      # Over the PROJECT's root, so a chat started in `services/ingest` mounts
      # the epic its project declares rather than whichever the working
      # directory happened to name.
      def epic_mount(notice)
        EpicMount.for(chronicle:, options:, notice:, notify: @notifier, root: project.root,
                      bindings: replies, **ReviewSeams.for(replies, root: project.root))
      end

      # The run's ONE live {HumanReplies}, late: it is built in #build_repl,
      # strictly AFTER the toolset, so every seam that needs it takes this same
      # thunk and reads it at CALL time. Closing over an IVAR rather than a local
      # is what makes it actually late.
      #
      # The splat of {ReviewSeams} above is what turned the changeset half of
      # `request_review` on. Passing only the notify and bindings keywords left
      # `changesets:` and `surface:` nil, so `Implementation#hold` answered
      # `Refusals.no_changeset` in every real process and the surface resolved to
      # the Null -- invisible to all 10865 examples, because a threaded-but-never
      # -injected seam looks identical to an absent one.
      def replies = -> { @replies }

      # The board owns Gate's policy behind the ONE PolicySwitch, writing it
      # itself as the derived consequence of a `/mode` flip; Gate stays
      # construction-fixed. Memoized because #wire_agent resolves it and
      # {AgentBuild} is handed what came back.
      #
      # #wire_agent calls this BEFORE `chronicle.start`, and that ordering is a
      # requirement, not a reading order: everything below can REFUSE
      # ({Project::Consent} reads this root's `[approval]` table, {BoardBuild}
      # compiles its `[sensitivity]` one), while `#start` writes the session
      # header -- so a refusal after it leaves a record on disk for a chat that
      # never ran. {#fleet_isolation} keeps the same ordering for the same reason.
      #
      # The toolset passed here is the BASE set every posture resolves from:
      # attenuation is monotone, so leaving `plan` must rebuild from what the
      # session was built with and never from what the previous posture left
      # behind. What comes back as `board.toolset` is the live slot the Agent and
      # its executor hold, so a `/mode` flip changes the rendered schema without
      # rebuilding either.
      #
      # What the path boundary is built FROM is {BoardBuild}'s question. Until
      # that module existed the board took the constructor's
      # {Lain::Sensitivity::Policy::Null} default, so `gates?` answered false for
      # every path in every real chat and the whole axis was dark.
      def switchboard(backend, toolset, notice = nil)
        @switchboard ||= BoardBuild.for(chronicle:, options:, model: backend.context.model, toolset:, project:, notice:)
      end

      # What the drain is handed is the DIRECTORY, not the run's one asker:
      # "which asker holds the set this answer names" is a question only the
      # directory can answer, and asking the parent's asker instead is how a
      # child's question becomes unanswerable. The {HumanReplies} drain is built
      # HERE rather than inside Repl so the Env's replies reader and the Repl's
      # collaborator are one object.
      def build_repl(tty:, agent:, backend:)
        @replies = HumanReplies.new(tty:, conductor: @conductor, ask_human: directory, questions:)
        @command_surface = assemble_surface(agent:, library: backend.library, tty:)
        # Bound rather than injected: the registry is built FROM this object, so
        # no constructor ordering exists in which HumanReplies could take one.
        # Both prompts then dispatch through the one bound registry, which is
        # what makes a command behave the same at `you> ` and at `human> `.
        @replies.bind_commands(@command_surface.commands)
        # Held, not merely returned: #exit_status asks the Repl what the
        # conversation reached, and the exe reads that after #run has returned.
        @repl = repl_over(tty:, agent:)
      end

      # Split off #build_repl because that method's ABC number was already at the
      # limit and reading `--non-interactive` was one send more than it had room
      # for. It is a different sentence anyway: the Repl over the collaborators
      # the lines above just settled.
      def repl_over(tty:, agent:)
        Repl.new(agent:, tty:, replies: @replies, chronicle: @chronicle, conductor: @conductor, approvals:,
                 notifier:, supervisor:, middleware: @command_surface.middleware, attended: attended?,
                 commands: @command_surface.commands, auto_surface:, secret_surface:, goal_driver:)
      end

      # Its own method because of an ABC trip, and the measurements are kept so
      # the next reader need not re-derive them: this method measures 6, and
      # build_repl with it inlined measures 18.11 against a limit of 17 (17.12
      # with the Repl's two surface kwargs folded into one splat).
      #
      # What holds it over is a DIFFERENT unnamed object, and the arithmetic says
      # so: `approvals`, `goal_driver` and `supervisor` are each read TWICE in
      # the inlined body, once for the Surface and once for the Repl, because
      # both are built from the same six collaborators this class holds -- the
      # repeated parameter list that named {ToolsetBuild}, showing up again. The
      # follow-ups in planning/specs/chunk-review-missing-objects.md carry it.
      # Do NOT clear the number by hoisting the three duplicate reads into
      # locals: that measures 15.81 and passes the cop by bending the method to
      # the limit, which is this comment's complaint one layer down.
      def assemble_surface(agent:, library:, tty:)
        Command::Surface.new(agent:, replies: @replies, supervisor:, role_spawn:, approvals:, goal_driver:, library:,
                             chronicle: @chronicle, status_feed: @status_feed, root: project.root, cwd: project.cwd,
                             **@switchboard.surface_kwargs(conductor: @conductor, tty:))
      end

      # Memoized, so the surface and the Repl poll ONE instance.
      def goal_driver = @goal_driver ||= GoalDriver.new(journal: goal_journal, quiescent: -> { quiescent? })

      # Asked INSIDE the memo, never above it: under --no-journal the answer
      # OPENS /dev/null, so hoisting it leaks one File per extra #goal_driver
      # call -- opened, discarded unread, never closed. Two readers poll the
      # driver, so that was a real leak rather than a hypothetical one.
      def goal_journal = chronicle.record_journal

      # Both observable halves of "do not drive while the fleet is unquiet": a
      # parked approval, and a human question waiting for an answer. The inbox
      # half is safe to read because {HumanReplies} is built in #build_repl
      # before the driver, so the slot is set by the time a poll can run.
      def quiescent?
        (approvals.nil? || approvals.each.all?(&:decided?)) && !@replies.pending?
      end
    end
  end
end
