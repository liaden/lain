# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

require_relative "wiring/askers"
require_relative "wiring/board_build"
require_relative "wiring/toolset_build"

module Lain
  module CLI
    # The chat-assembly responsibility, lifted out of the Thor class the way Repl
    # was: a chat's Agent -- toolset, subagent, approval gate, provider spool and
    # the ask_human reply seam -- is its own job. It hands back the built Agent
    # and exposes the asker/question pair so #run_chat can give the Repl the
    # reply path this object wired.
    #
    # Five collaborators that lived in their own files under `wiring/` are back
    # in this body, and the record of why is worth stating exactly rather than
    # generously. ONE of them -- the agent build -- named a
    # `Metrics/ClassLength` budget outright as the reason it left, and that is
    # the extraction a counter really drove. The other four named no second
    # responsibility at all: they were single-caller shards, each reached from
    # exactly one line of this class, and each bought about a line against the
    # thirty-odd it occupied in a reader's scroll, because the cop DISCOUNTS a
    # nested body. A file is not a seam, so they came home when nothing was
    # left arguing for them.
    #
    # {BaseTools} is the one exception to "reached from this class": its caller
    # is {ToolsetBuild}, which builds the floor once for the parent and again
    # for every child. It stays a module here for that reason, not for a cop's.
    #
    # What stayed out stayed for a reason that is not a counter. {ToolsetBuild}
    # is constructed from three further sites in `cli/epic_driver/factory.rb`.
    # {Askers} holds live `Async::Queue` state. {BoardBuild} turns a project's
    # config into authorities -- which tables GRANT, which RESTRICT, and what
    # each costs when one will not parse -- and that is a different job from
    # assembling a chat.
    #
    # Still unnamed: the object {#assemble_surface} wants. Neither obvious seam
    # takes it -- #assemble_surface cannot leave, because `wiring_spec.rb`
    # drives it directly to assert the switchboard memo is set by the time the
    # surface is assembled; #run cannot, because it orchestrates this class's
    # own assembly steps, so an object holding it would have to be handed this
    # one, which is a god-object handle.
    class Wiring
      # What a human is told is asking when the question came from the chat they
      # are having rather than from something it spawned. A fact about THIS
      # agent, not about the seam: a child passes its own role.
      MAIN_AGENT = "lain"

      # The capability policy every chat runs under -- see {#journal_degradation}
      # for why `:strict`, the only other member of {Capability::Policy::NAMES},
      # cannot be the value here.
      DEGRADE = :degrade

      # A file the whole chat reads cannot take the chat down with it, and a
      # worker handed back with lain's defaults is still handed back.
      UNREAD = "the [isolation] settings in .lain/config.toml were not read, so workers hand back " \
               "with lain's defaults: %<reason>s"

      private_constant :UNREAD

      Handback = Data.define(:handoff, :sync)

      # How a worker's work comes home on the chat path: the
      # {Isolation::WorkerHandoff} a one-shot child's lease ends in -- the same
      # one the {Supervisor} surrenders a crashed actor through, so the two
      # lanes cannot hand work back to different places -- and the
      # {Isolation::SelfSync} that rebases a child onto the working branch
      # before that handback runs. {Wiring#handback} builds it.
      #
      # Reopened rather than declared in a `Data.define ... do` block: a
      # constant there is lexically scoped to the enclosing class.
      class Handback
        # The resolver a conflict spawns is the run's ONE {Skill::RoleSpawn},
        # which {ToolsetBuild} builds after the {Supervisor} holding this
        # handoff. So it is read at call time, never captured, and never built
        # twice: a second RoleSpawn would be a second answer to which seam a
        # child spawns over.
        LateResolver = Data.define(:role_spawn) do
          def call(role_name, context_mode, prompt) = role_spawn.call.call(role_name, context_mode, prompt)
        end

        # The sync defaults to nothing, which is what a handoff with no
        # working branch needs. Resolved in the signature, at call time,
        # because `lain/cli` loads before `lain/isolation`.
        def initialize(handoff:, sync: Isolation::SelfSync::Null) = super

        def self.none = new(handoff: Isolation::WorkerHandoff::Null)
      end

      # The chat's capability floor -- the tier-1 structured tools plus tier-3
      # bash -- before the subagent and the ask_human reply seam layer on. The
      # union a subagent role attenuates FROM is exactly this list, so it is
      # built once and shared.
      #
      # A module rather than one of this class's own methods because
      # {ToolsetBuild} calls it: the floor is built once for the parent and
      # again for every child, from an object that is not this one.
      module BaseTools
        module_function

        # @param recorder [Lain::Memory::Recorder] the ONE recorder backing the
        #   memory tools for the whole session
        # @param exec [#call] the {Lain::Exec} backend {Lain::Tools::Bash}
        #   becomes a process through -- `--exec`, resolved by
        #   {Lain::CLI::ExecBackend} at the site that knows the project's root.
        #   Defaulted rather than required so the callers that only want the
        #   floor's SHAPE stay byte-identical to before the flag existed.
        # @param verdict [#call] `String -> Shell::Verdict::Decision`, the
        #   session's ONE shell verdict -- the object {Lain::Tools::Bash} picks
        #   its arm with AND the object the approval ladder's triage rung
        #   judges with. {Lain::CLI::Wiring} builds it from the project's
        #   `[shell]` table and hands the same instance to both. {Wiring#verdict}
        #   is where that sharing is stated and where the memo that makes it
        #   true lives; this parameter is the tool's end of it.
        #
        #   The default restricts no program, so a floor built with no session
        #   -- `bash_spec` constructs the tool alone, and
        #   {Lain::Tools::Subagent} runs an ungated handler -- is unchanged.
        #   Sharing the instance is an INJECTION and never a dependency: the
        #   tool must stay correct with nobody above it. The default is written
        #   here rather than in a constant because `lain.rb` loads `lain/cli`
        #   before `lain/shell`, so it can only be resolved at CALL time --
        #   the same debt `escalation.rb` records at the other seam.
        #
        #   == A DENY MOVES THE COMMAND ONTO THE LESS CONSTRAINED ARM
        #
        #   Stated here because this is where the verdict reaches the object
        #   that picks the arm, and a reader reasoning about arms will not
        #   think to look at a Switchboard keyword. `Tools::Bash#perform` is
        #   `decision.allow? ? decision.term : input.command`, so `deny` and
        #   `abstain` are one branch to it. MEASURED, through the real tool
        #   over a recording backend:
        #
        #     no table          curl http://example.com  allow  [["curl","http://example.com"]]
        #     exclude = ["curl"] curl http://example.com  deny   "curl http://example.com"
        #
        #   So excluding a program takes it OFF the reconstructed argv this
        #   layer exists to produce and onto `sh -c` -- more shell, not less,
        #   for the one program the project named. Attended sessions never see
        #   it, because the ladder's triage rung denies before the tool is
        #   reached. The two postures that DO reach the tool are exactly the
        #   two that skip the ladder: `/mode auto`, whose gate policy is
        #   {Middleware::Gate::ApproveAll}, and a child of a run with no chat,
        #   whose gate {CLI::ToolGuard.detached} builds over the same class.
        #
        #   NOT a defect this card may fix: what a deny should MEAN at the tool
        #   -- refuse outright, or run as a term anyway -- is a design question
        #   about the tool's contract rather than about the wiring, and the
        #   answer changes `Tools::Bash`. Named instead as the NEXT RUNG on the
        #   "what reaches a shell" axis, whose position today is "understood
        #   commands run as reconstructed argv; everything else through `sh
        #   -c`": the rung after it is a deny that does not fall through to the
        #   string arm.
        # @param journal [#<<] the session's journal, where {Lain::Tools::Bash}
        #   writes the {Lain::Telemetry::ShellArm} record of every call's arm.
        #   Handed down by {Lain::CLI::Wiring::ToolsetBuild}, which holds the
        #   run's one journal already. Null by default for the same reason
        #   `verdict:` is permissive by default -- a floor built with no session
        #   behind it must still work -- and, for the same reason, the default is
        #   what a spec has to drive PAST rather than through, or arm selection
        #   would go unrecorded in every real session while looking wired here.
        def build(recorder, exec: Lain::Exec::Local.new, verdict: Lain::Shell::Verdict.new,
                  journal: Lain::Channel::Null.instance)
          [Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new, Lain::Tools::Glob.new, Lain::Tools::Grep.new,
           Lain::Tools::EditFile.new, Lain::Tools::WriteFile.new, Lain::Tools::TodoWrite.new,
           Lain::Tools::MemoryWrite.new(recorder:), Lain::Tools::MemoryRead.new(index: recorder),
           Lain::Tools::Bash.new(exec:, verdict:, journal:), Lain::Tools::WebFetch.new, Lain::Tools::WebSearch.new,
           Lain::Tools::AstDump.new, Lain::Tools::TestPattern.new, Lain::Tools::AstSearch.new,
           Lain::Tools::FileSymbols.new]
        end
      end

      attr_reader :ask_human, :askers, :supervisor, :conductor, :command_surface, :project

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

      # The run's ONE line to the human at the terminal, late for {#replies}'
      # reason and read the same way: the frontend is built in #run, strictly
      # AFTER the toolset, so what is handed downward is this thunk and the slot
      # behind it is read at CALL time.
      #
      # It is the seam `request_review` hands a waiting file over on, and it is
      # now the ONLY one -- production wires no editor ({EpicMount#request_review}
      # says why), so a review nobody is told about parks on an unbounded await
      # with nothing anywhere naming the file. Public for the reason the notifier
      # reader it replaces was public: a spec asking what a wired chat can say to
      # a human asks the object rather than reaching past it.
      def told = ->(text) { @human_line.call(text) }

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
      # @param paths [Paths] the state home the default posture's shadow
      #   snapshot store lives under; a spec running tool turns hands in a
      #   throwaway one
      # @param tty_factory [#call] #run's TTY seam; a spec hands in a StringIO-backed one
      # @param conductor_opener [#call] #run's Conductor seam
      # @option options [String] :prompt the first question, seeded from --prompt
      # @option options [Numeric] :grace seconds a first Ctrl-C grants a run
      # @option options [String] :isolation the backend a fleet leases workers from
      def initialize(options:, chronicle:, status_feed:, run_clock: Lain::RunClock.new, paths: Lain::Paths.new,
                     project: Project::Resolver.default_project,
                     tty_factory: Lain::Frontend::TTY.public_method(:new),
                     conductor_opener: Lain::CLI::Conductor.public_method(:open))
        @options = options
        @chronicle = chronicle
        @status_feed = status_feed
        @run_clock = run_clock
        @paths = paths
        @project = project
        @tty_factory = tty_factory
        @conductor_opener = conductor_opener
        # Nobody is looking at anything until #run builds a frontend, and that
        # is the honest value for the window -- not a stand-in for one.
        @human_line = SILENT
      end

      # Assemble the run's collaborators over the now-open chronicle and hand off
      # to the frontend. The conductor slot is set BEFORE the repl blocks, so the
      # exe's ensure can close it even when the repl raises mid-run.
      def run(backend:, resumed:, nvim:, &notice)
        recorder, session = run_state(resumed)
        agent = wire_agent(channel: Lain::Channel.new, recorder:, session:, backend:, resumed:, views: nvim, notice:)
        resumed&.notices&.each(&notice)
        tty = @tty_factory.call(channel:, prompt_renderer: prompt_renderer(agent, notice))
        @human_line = tty.method(:render_warning)
        @conductor = open_conductor(tty)
        @conductor.guard do
          build_repl(tty:, agent:, backend:).run(**editor_seams(nvim, agent, session), first_prompt: @options[:prompt])
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

      # What a chat's RUN STATE is, fresh or resumed: the memory recorder and the
      # journaled Session.
      #
      # THE INVARIANT: one Recorder backs the memory_write tool for the whole
      # session -- the single mutable holder of the live {Lain::Memory::Index},
      # so each write supersedes the last. A resumed chat inherits the
      # chain-wide recorder instead, so its manifest sees every memory the
      # resumed sessions wrote. BOTH halves must then be decorated by the
      # chronicle: reads and todos journal through {Lain::Session::Journaled},
      # and each turn_usage pairs with the memory root in force, so decorating
      # one and not the other is a run whose usage records name a memory root
      # its reads never wrote. That is why the pair is built in one place and
      # handed back together. Identity under --no-journal.
      #
      # A fresh Session runs at the {Lain::Project}'s cwd, answered by
      # {#chat_env}; only actor-mode subagents lease an environment, because the
      # user's own edits belong in the user's own tree.
      #
      # PUBLIC surface: four spec files drive `wiring.run_state(nil)` to get a
      # real recorder and session to build an assembly against.
      #
      # @param resumed [#recorder, #session, nil] the resumed chat, nil when fresh
      # @return [Array(Lain::Memory::Recorder, Lain::Session)] the recorder, and the journaled session
      def run_state(resumed)
        recorder = resumed ? resumed.recorder : Lain::Memory::Recorder.new
        session = resumed ? resumed.session : Lain::Session.new(memory: recorder, worker_env: chat_env)
        chronicle.wrap_memory(recorder)
        [recorder, chronicle.wrap_session(session)]
      end

      # The main chat's host-side context, at the PROJECT's cwd rather than at
      # whatever `Dir.pwd` was when the default was computed. Deliberately not a
      # leased environment -- see #fleet_isolation: the user's own edits belong
      # in the user's own tree.
      def chat_env = Lain::WorkerEnv.default.with(cwd: project.cwd)

      def wire_agent(channel:, recorder:, session:, backend:, resumed: nil, views: nil, notice: nil)
        # The run's ONE Channel, in a slot for the reason `@agent` carries below:
        # the collaborators that journal onto it are assembled across three
        # methods here, so a value threaded through each of them is a promise
        # every caller has to keep where the slot is a fact this object holds.
        @channel = channel
        parent = -> { @agent.timeline }
        @supervisor = supervise(notice)
        @ask_human = wire_askers(parent)
        toolset = build_toolset(recorder, backend:, parent:, ask_human: @ask_human, notice:)
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

      # What the Repl builds its editor from, as the one set it is: the views
      # to attach, the Store and Session its buffers read, and the epic
      # lain://status draws. {ReviewSeams}' splatted-hash shape, for the same
      # reason -- the keywords travel together.
      def editor_seams(nvim, agent, session)
        { nvim:, store: bind_hud_store(agent), session:, epic: epic_status }
      end

      # The backend a run leases every worker's WorkerEnv from -- the actors a
      # {Supervisor} adopts AND the children a model dispatches, which
      # {ToolsetBuild} is handed this same instance for. The main chat's Session
      # is built on {WorkerEnv.default} deliberately, because the user's own
      # edits belong in the user's own tree.
      #
      # MEMOIZED, and the sharing is not an optimization. Every consumer keys
      # its resources on a worker id and allocates from per-INSTANCE state: a
      # {Isolation::Worktree}'s `@leased` Set and Monitor serialize one object,
      # so two backends cannot refuse each other's checkout paths, and a
      # service pool that allocates without a worker key in it hands the same
      # slot out twice. `.lain/services.rb` is read once for the reason
      # {IsolationBackend#services} gives about a file edited mid-resolution.
      #
      # It takes NO argument, and that is the memo's own honesty: a `journal:`
      # parameter would be honoured on the first call and silently discarded on
      # every later one, so the signature would promise a choice the object does
      # not offer. The run's one Channel is a slot instead.
      #
      # Resolved on the first call, before the chronicle pins its header, so an
      # unrecognized name refuses while the session record is still empty -- the
      # refusal-before-journal ordering --resume already keeps.
      #
      # The root is the {Project}'s, not `Dir.pwd`: it is what
      # `.lain/services.rb` is read from and where the repository search starts,
      # so a run from a subdirectory declares the services its PROJECT
      # declares.
      def fleet_isolation = @fleet_isolation ||= IsolationBackend.resolve(options[:isolation], root:, journal: channel)

      # The run's ONE Channel, and {Lain::Channel::Null} until {#wire_agent} has
      # opened one: a Wiring driven straight at a private assembly seam -- which
      # two specs do -- journals nowhere rather than handing a collaborator nil
      # to push records onto.
      def channel = @channel || Lain::Channel::Null.instance

      # The PROJECT's root, which is what every collaborator below is handed:
      # never `Dir.pwd`, so a chat started in a subdirectory still resolves
      # against the project it belongs to.
      def root = project.root

      # Assembled HERE because this is the only object holding the live Agent,
      # the run's RunClock and the StatusFeed at once -- the three things a
      # prompt format writes against. A malformed config reports through the same
      # startup-notice seam a resumed chat's notices use, which is why the block
      # is threaded down.
      #
      # `mode: @switchboard.mode_switch` is the ivar, not the private
      # `#switchboard` method: by the time #run calls this, #wire_agent has
      # already memoized it, and reaching for the live slot directly is what
      # makes a later `/mode` flip show at the very next prompt -- the whole
      # point of handing the RunState a switch rather than a snapshotted Mode.
      def prompt_renderer(agent, notice)
        state = Frontend::PromptComposer::RunState.new(agent:, clock: run_clock, status_feed: @status_feed,
                                                       mode: @switchboard.mode_switch)
        Frontend::PromptComposer.renderer(state:, notify: notice || SILENT)
      end

      # The seam `spec/lain/cli_spec.rb` drives, which is what pins `session:` as
      # required: a defaulted fresh Session would silently mis-wire memory. It
      # takes the resume RESULT rather than a `timeline:` lifted off it --
      # reading `resumed&.timeline` at the caller cost #wire_agent the one
      # branch that put it over AbcSize.
      def build_agent(toolset:, channel:, session:, backend:, resumed: nil, views: nil, notice: nil)
        agent_over(board: switchboard(backend, toolset, notice), channel:, session:, backend:,
                   timeline: resumed&.timeline, views:)
      end

      # What the Agent is built FROM: the provider the run talks to, the
      # compaction wiring hung off it, the instrumentation stack, and the
      # executor the tool stack ends in.
      #
      # The board ARRIVES as an argument rather than being resolved here, and
      # that is load-bearing: {#switchboard} is memoized at its ONE call site,
      # and {#approvals}, the command surface and the board thunk every
      # subagent's tool stack is built over all read that memo afterwards. A second resolution
      # down here would leave all three reading a different board -- or nil.
      #
      # The Agent's ONE Toolset is the board's, not the caller's, because a
      # `/mode` flip changes the live slot without rebuilding anything: its
      # runner resolves each call against it once, and the gate and the Live
      # executor both judge that one resolution. `views:` exists
      # because a streamed tool's bytes are a view, not a record, so the
      # executor writes them to the TTY Channel AND the editor's -- never to
      # the journal, which already holds them in the turn's tool_result.
      #
      # The `tap` gives the turn middleware's thunk a live agent binding. It is
      # ASSIGNED, not merely returned: the thunk is built before the Agent it
      # reads, so left as a bare return expression the local stays nil forever
      # and the first turn raises NoMethodError on it.
      def agent_over(board:, channel:, session:, backend:, timeline: nil, views: nil)
        live = Lain::Effect::Handler::Live.new(channel: LiveViews.tool_output(channel, views))
        agent = nil
        Lain::Agent.new(toolset: board.toolset, context: board.graft(backend.context), handler: live, session:,
                        timeline:, request_override: Lain::Agent::RequestOverride.new, # ResendBridge's slot
                        snapshot_slot: snapshot_slot(board, journal: chronicle.record_journal, channel:),
                        **backing(backend, channel, -> { agent.timeline }, board:)).tap { |built| agent = built }
      end

      # Born here, under the posture the board starts in, and handed to the
      # board, because the board is the one object a `/mode` flip goes through
      # ({Switchboard#apply} rebinds it). The board's own build is not where it
      # can be born: that runs before any root reaches it. The root is the
      # PROJECT's, where every snapshot is rooted, and `paths:` the state home a
      # shadow snapshot scope keeps its store in.
      def snapshot_slot(board, journal:, channel:)
        Lain::Agent::SnapshotSlot.new(root:, scope: board.snapshot_scope, paths: @paths, journal:,
                                      channel:).tap { |slot| board.bind_snapshots(slot) }
      end

      # The provider, and the compaction wiring hung off it -- the per-turn
      # Context source, the eager-summary observer, and the journal tee that
      # feeds the source the cache-read counts the render seam cannot see
      # ({CompactionMount}). One method, because the mount must reference THE
      # ONE provider the run talks to: {Compaction::Cold} compares idle time
      # against that provider's own cache TTL, so a second construction would
      # be a second answer.
      #
      # The mount is deliberately NOT memoized. Every piece of run state it
      # hands over is memoized in {Backend}, which is loud about a differing
      # rebind ({Backend::Rebound}); the mount is a pure assembler over those,
      # so a memo here would only add a second place for a stale collaborator
      # to hide. `board:` reaches {ToolGuard}, which builds the whole tool stack
      # over the board's one set of inputs -- so this agent releases into the
      # run's one region ledger, and its gate asks the run's one policy, rather
      # than a second nobody reads. The stack's order is a security posture,
      # and {ToolGuard} is where it is stated.
      def backing(backend, channel, timeline, board:)
        provider = spooled_provider(backend, channel:)
        journal_degradation(backend.context, provider, journal: chronicle.record_journal)
        mount = CompactionMount.new(backend:, provider:, chronicle:, channel:)
        # The run's ONE window book, the same instance the compaction source
        # and the StatusFeed divide by, so the REPL prompt's `ctx` segment and
        # the state feed cannot report two occupancies for one turn.
        #
        # The ANSWER inside it is refreshable and the trigger lives here,
        # OUTSIDE the book: {Middleware::ResolveWindow} re-resolves once per
        # turn until the answer is authoritative. The book has no clock and no
        # turn count, and one that re-resolved per READ would let a single
        # turn's three readers see three windows.
        window = backend.context_window
        { provider:, context_window: window,
          instrumentation: mount.instrumentation.with(tool_middleware: ToolGuard.stack(chronicle, board),
                                                      turn_middleware: turn_phase(timeline, window)) }
      end

      # The turn stack, with the window refresh OUTERMOST -- ahead of the
      # chronicle's own members, because re-resolving a denominator is not part
      # of the turn a journal records, and everything downstream that reads a
      # window must see the refreshed one. A {Middleware::Stack}, because the
      # ordering is the footgun and a Stack is the shape that stays inspectable.
      def turn_phase(timeline, window)
        Middleware::Stack.new([Middleware::ResolveWindow.new(book: window),
                               *chronicle.turn_middleware(timeline).to_a])
      end

      # WRITE what this run's Context asks for that its Provider cannot give --
      # one `capability_degraded` record per missing capability, once per
      # session. {Capability::Policy} shipped with a record type, an emitter and
      # a reader and NO caller: twelve POC journals carried zero such records
      # while {Context::CacheBreakpoints} required `:prompt_caching` from an
      # ollama provider that does not declare it, and {Compare} refuses to
      # compare runs whose degraded sets differ -- so the gap made incomparable
      # runs look comparable.
      #
      # Named for the WRITE, not the negotiation: {Capability::Policy#resolve}
      # does hand back a {Capability::DegradedSet} and it is dropped here
      # deliberately, because nothing in a live chat consumes one ({Compare} and
      # {Bench::Session::Loader} rebuild it from the journal, which is the
      # durable answer).
      #
      # `:degrade` is the ONLY policy that may be wired here.
      # `Policy::Strict#handle_missing` calls {Provider#require!}, which raises
      # {Provider::Unsupported} -- so `:strict` would kill every ollama chat at
      # turn one. A constant is the honest shape until someone asks for a flag.
      #
      # Session-scoped, not per-turn: {Bench::Session::Loader#degraded} folds
      # these to a set, so a per-turn emission would flood the record with
      # nothing downstream complaining.
      #
      # @param context [#requires] the Context this run renders through
      # @param provider [#supports?] the ONE provider this run talks to
      # @param journal [#<<] where each record lands -- the run's own, and a
      #   Journal rather than the Chronicle that resolves it, so this depends
      #   on the one message it sends (`Policy.for`'s own `journal:` keyword)
      #   and a spec can hand it a StringIO-backed {Lain::Journal} without
      #   constructing a Chronicle
      def journal_degradation(context, provider, journal:)
        Lain::Capability::Policy.for(DEGRADE, journal:).resolve(context, provider)
      end

      # Both provider construction sites tee their round trips into the
      # chronicle's response spool. `channel:` is the live TTY Channel for the
      # MAIN agent (stream_started reaches the frontend); a subagent leaves the
      # Null default, since its stream is not rendered and only the spool tee
      # matters there.
      def spooled_provider(backend, channel: Lain::Channel::Null.instance)
        backend.provider(spool: chronicle.spool, channel:)
      end

      # A resumed chat opens its NEW journal chained to the old one. Derived from
      # the Resume result so the exe never assembles the wire-format hashes.
      def resume_start(resumed) = resumed ? { resumed_from: resumed.resumed_from, written: resumed.written } : {}

      # The run's ask-the-human seam, and the parent agent's own asker off it.
      # The registration that comes back is dropped ON PURPOSE: this asker is
      # routable for exactly as long as the run. A CHILD's must be kept and
      # deregistered on the lease that reaps it -- see {Askers::Enrolled}.
      def wire_askers(parent)
        @askers = Askers.new(observer: chronicle.observer, attended: attended?)
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
      def build_toolset(recorder, backend:, parent:, ask_human:, notice: nil)
        @toolset_build = ToolsetBuild.new(backend:, provider: spooled_provider(backend),
                                          chronicle:, options:, root:, usage: -> { @agent&.usage }, askers: @askers,
                                          supervisor: @supervisor, parent:, library: backend.library,
                                          switchboard: -> { @switchboard }, journal: channel, verdict: verdict(notice),
                                          isolation: fleet_isolation, handback: handback(notice),
                                          epic: epic_mount(notice))
        @toolset_build.build(recorder, ask_human:)
      end

      # The reactor above the Agent that un-refuses model-dispatched actors,
      # run by the exe under a chat-level reactor that outlives asks. It leases
      # from the fleet's one backend and surrenders a crashed actor through the
      # run's one handoff.
      def supervise(notice)
        Lain::Supervisor.new(journal: channel, isolation: fleet_isolation, handoff: handback(notice).handoff)
      end

      # How a worker's work comes home, built ONCE and handed to both lanes --
      # the {Supervisor}'s crashed actors and {ToolsetBuild}'s one-shot children
      # -- so the two cannot hand work back to different places. Memoized for
      # {#verdict}'s reason: the notice fires on the first call. Every caller
      # names the notice, so which one came first cannot decide where a broken
      # table is told.
      #
      # The Supervisor is built before the toolset, so the resolver reads the
      # run's {Skill::RoleSpawn} through a thunk at call time.
      # Built from the fleet's isolation, which names the working branch, and
      # from the project's `[isolation]` table, which names the merge strategy
      # and the rebase retries. With no branch named no checkout was cut, so
      # nothing is synced and the handoff only releases: a handback run over the
      # chat's own tree would read the human's work as a worker's.
      #
      # @return [Handback]
      def handback(notice)
        @handback ||= begin
          base = fleet_isolation.base
          base.name.empty? ? Handback.none : handback_over(base, isolation_settings(notice))
        end
      end

      # The repository a handback merges into is the backend's OWN -- the same
      # one it cut worker checkouts from -- never a root re-derived here, which
      # could disagree with it under GIT_CEILING_DIRECTORIES.
      def handback_over(base, settings)
        strategy = Isolation::MergeStrategy.from(settings)
        resolver = Handback::LateResolver.new(role_spawn: -> { role_spawn })
        Handback.new(handoff: Isolation::WorkerHandoff.over(repo_root: fleet_isolation.repo_root, base:,
                                                            journal: channel, strategy:, resolver:),
                     sync: Isolation::SelfSync.new(base:, strategy:, retries: settings.rebase_retries))
      end

      def isolation_settings(notice)
        Config.load(root:).isolation
      rescue Lain::Error, SystemCallError => e
        notice&.call(format(UNREAD, reason: e.message))
        Config::Isolation.empty
      end

      # Which epic this chat is seated in, resolved ONCE and read twice: the
      # toolset takes the mount's tools, and an attached editor's lain://status
      # takes its slug. One mount rather than two because {EpicMount} builds the
      # one {Epic::Review} per slug, and a second mount would be a second guard
      # over one journal.
      #
      # The splat of {ReviewSeams} is what turns the changeset half of
      # `request_review` on. Passing only the bindings keyword left
      # `changesets:` and `surface:` nil, so the implementation stage refused in
      # every real process -- invisible to any spec, because a threaded but
      # never injected seam looks identical to an absent one.
      #
      # The root is the PROJECT's, so a chat started in `services/ingest` mounts
      # the epic its project declares rather than whichever the working
      # directory happened to name.
      #
      # @param notice [#call, nil] told why a mount was abandoned; heard by the
      #   FIRST call only, which is the toolset build's
      # @return [EpicMount, EpicMount::NoEpic]
      def epic_mount(notice = nil)
        @epic_mount ||= EpicMount.for(chronicle:, options:, notice:, told:, root:, bindings: replies,
                                      **ReviewSeams.for(replies, root:))
      end

      # What lain://status draws. {EpicMount::NoEpic} answers only `tools` --
      # which epic this is has no honest null -- so the CLI's null becomes the
      # frontend's here, once. The fold reads the same root and default state
      # home the mount resolved against, so the buffer folds the epic the mount
      # found.
      #
      # @return [Frontend::Neovim::StatusView::Mounted, Frontend::Neovim::StatusView::Unmounted]
      def epic_status
        return Frontend::Neovim::StatusView::Unmounted if epic_mount.equal?(EpicMount::NoEpic)

        Frontend::Neovim::StatusView::Mounted.new(slug: epic_mount.slug, status: Epic.new(root:))
      end

      # The run's ONE live {HumanReplies}, late: it is built in #build_repl,
      # strictly AFTER the toolset, so every seam that needs it takes this same
      # thunk and reads it at CALL time. Closing over an IVAR rather than a local
      # is what makes it actually late.
      def replies = -> { @replies }

      # The board owns Gate's policy behind the ONE PolicySwitch, writing it
      # itself as the derived consequence of a `/mode` flip; Gate stays
      # construction-fixed. Memoized because #wire_agent resolves it and
      # {#agent_over} is handed what came back.
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
        @switchboard ||= BoardBuild.for(chronicle:, options:, model: backend.context.model, toolset:, project:,
                                        notice:, verdict: verdict(notice))
      end

      # The session's ONE {Lain::Shell::Verdict}, and the memo is the whole
      # mechanism. #build_toolset gives it to the bash tool and #switchboard
      # gives it to the approval ladder's triage rung, so the gate and the tool
      # hold the same frozen, pure object: two holders of one instance compute
      # the identical Decision from the identical String, which makes "the
      # journalled verdict is the verdict the tool acted on" true by
      # construction and leaves nothing to be carried -- or forged -- between
      # them. Built HERE because the toolset is finished before the board
      # exists, so neither branch can build it for the other.
      #
      # Reached first from #build_toolset, which is ahead of `chronicle.start`:
      # the same refusal-before-journal ordering #switchboard keeps, and it
      # matters because a malformed `[shell]` table refuses rather than
      # degrading. The notice is passed on every call and fires on the first,
      # for {BoardBuild.for}'s reason -- one broken config, one sentence.
      def verdict(notice = nil) = @verdict ||= BoardBuild.shell_verdict(project:, notice:)

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
        @repl = Repl.new(agent:, tty:, replies: @replies, chronicle: @chronicle, conductor: @conductor, approvals:,
                         supervisor:, middleware: @command_surface.middleware, attended: attended?,
                         commands: @command_surface.commands, auto_surface:, secret_surface:, goal_driver:)
      end

      # Its own method because it is a DIFFERENT unnamed object, which the
      # duplication says out loud: `approvals`, `goal_driver` and `supervisor`
      # are each read twice across this method and #build_repl, once for the
      # Surface and once for the Repl, because both are built from the same six
      # collaborators this class holds -- the repeated parameter list that named
      # {ToolsetBuild}, showing up again. The follow-ups in
      # planning/archive/chunk-review-missing-objects.md carry it. Hoisting the
      # duplicate reads into locals would hide the tell without naming the
      # object.
      def assemble_surface(agent:, library:, tty:)
        Command::Surface.new(agent:, replies: @replies, supervisor:, role_spawn:, approvals:, goal_driver:, library:,
                             chronicle: @chronicle, status_feed: @status_feed, root: project.root, cwd: project.cwd,
                             epic: EpicDriver::Seams.new(mount: epic_mount, paths: @paths, journal: channel,
                                                         toolset_build:, asker: @ask_human, conductor: @conductor),
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
      def quiescent? = (approvals.nil? || approvals.each.all?(&:decided?)) && !@replies.pending?
    end
  end
end
