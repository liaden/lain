# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # What capabilities a run holds, and how a child inherits them.
      #
      # The set is layered, and the layering is the policy. {BaseTools} is the
      # capability floor, and it is ALSO the union a child attenuates from --
      # the same `base` is what {Skill::RoleSpawn} and {Tools::Subagent} are
      # handed, while `ask_human`, {Tools::RunSkill} and the epic's own tools
      # are appended AFTER, main-agent-only.
      #
      # Two of those are main-agent-only because the CONVERSATION is: a child
      # must not render a skill scaffold back into a conversation that is not
      # the one the human is having, and {Tools::RequestReview} PARKS holding
      # an artifact's baton, which belongs to the epic the human is watching. A
      # child MAY ask the human; what it must not inherit is the PARENT's
      # asker -- whose questions would be attributed to the parent's chain and
      # whose promise the parent's {AskHuman::Outstanding} holds -- so the
      # floor carries none and {Tools::Subagent::ChildBuilder} enrols one per
      # child on the run's {Askers}, over the child's own handle.
      #
      # {#role_spawn} and {#auto_surface} are readable only once {#build} has
      # run, because they are things the build DISCOVERS rather than things it
      # is told.
      class ToolsetBuild
        # == Why both seam axes read the board through a thunk, not as values
        #
        # {Tools::Subagent::Seam} is a frozen `Data` built ONCE, here, and the
        # run's {Switchboard} does not exist yet: the board requires the base
        # `toolset:` that {#build} RETURNS. Asking for the board here is a
        # construction cycle, not an argument that was forgotten, so it arrives
        # as a thunk read later.
        #
        # The cycle is not the only reason. A captured
        # `mode_switch.posture.permits` freezes the child's capability rule at
        # session start, so a mid-session `/mode plan` would journal, repaint
        # the HUD, attenuate the parent -- and leave every child holding
        # `bash`, silently, which is the same failure as not gating at all.
        # The {Context::ModelSwitch} / {Approval::PolicySwitch} rule: a live
        # change is a slot the holder already has, never a setter.
        #
        # Two seam members read it, at two different moments. `permits` is
        # asked per SPAWN, so a child already running keeps the plain {Toolset}
        # it was rendered ({Tools::Subagent::ChildBuilder#permitted}). The tool
        # guard ({CLI::ToolGuard::Spawned}) reads the board once per child, as
        # the child is built, and builds the parent's own stack over it -- gate
        # included, holding the board's one policy switch, so a `/mode` flip
        # reaches the child's next gated call through the slot it already has.
        PosturePermits = Data.define(:board) do
          def include?(tool_name) = board.call.mode_switch.posture.permits.include?(tool_name)
        end

        # What a child announces itself as at the approval gate when the spawn
        # bound no more specific name -- the tool's own default `name`, so a
        # park is at least separable from the human's own agent
        # ({Approval::Queue}'s `requester:`) without claiming an identity the
        # spawn never took.
        SPAWN_REQUESTER = "subagent"

        # The role the chat's own subagent spawns, named ONCE: what it may do
        # (its `only`-set, through {Backend#spawn_policy}) and what a human is
        # told it is (its arrival note) are two readings of one fact, and two
        # literals is how they drift.
        RESEARCHER = :researcher

        # The role the epic's Subagent grants and the one its children take.
        # The orchestrator runs a whole plan in ONE ask, so the default
        # 25-iteration ceiling would cut it off mid-plan.
        ISSUE_ORCHESTRATOR = :issue_orchestrator
        IMPLEMENTER = :dev

        # The role a reviewing child takes: it reads and searches the code it
        # judges, and holds nothing that writes or reaches the network.
        REVIEWER = :reviewer_code
        ORCHESTRATOR_BUDGET = Lain::Agent::Budget.new(max_iterations: 200)

        # The orchestrator, and one level of children under it.
        EPIC_DEPTH = 2

        # The repl-phase role-spawn seam a role/skill line folds through (nil
        # until {#build}), the opt-in third approval surface over it (nil
        # without --auto-approve), and the docent ANSWERER -- an answerer and
        # not a {Review::Docent} because a docent is keyed to a changeset and a
        # thread pane, and neither exists at toolset-build time. What a RUN
        # holds is the capability to spawn the role.
        attr_reader :role_spawn, :auto_surface, :docent

        # The run's collaborators, each INJECTED rather than resolved here for
        # one reason: a second construction site would be a second answer to a
        # question the run may only have one answer to -- which spool round
        # trips tee into, which skill tree /help read, which epic a chat is in,
        # what mode the session is in, who is holding a parked question.
        #
        # @param backend [Backend] the run's provider/model choice ({CLI::Backend}) --
        #   read here for `backend.context` (the child seam's context factory) and
        #   `backend.spawn_policy` (the researcher role-spawn's `only`-set)
        # @param provider [Provider] the run's ONE spooled provider ({Wiring} builds
        #   the only other one), so both construction sites agree on which spool
        #   round trips tee into
        # @param chronicle [Chronicle] read once for `chronicle.observer`, folded
        #   into the one spawn {Lain::Tools::Subagent::Seam} both child seams
        #   travel over
        # @param options [Hash] the parsed CLI options
        # @param supervisor [Supervisor] the supervisor a spawned actor adopts
        #   its isolation lease from and runs under ({Tools::Subagent#supervisor})
        # @param parent [#call] a thunk reading the live parent Timeline --
        #   the subagent tool reads the head at SPAWN time, so this must stay
        #   late-bound.
        # @param journal [#<<] the journal {Wiring} hands down, and two things
        #   ride it from here: a spawned child's lifecycle events
        #   ({Tools::Subagent#journal_lifecycle}), and the record
        #   {Lain::Tools::Bash} writes of which arm each shell command ran on,
        #   which {BaseTools} takes as its own keyword. Kept in the spawn seam
        #   and read back off it rather than also held in an ivar here: the
        #   {Tools::Subagent::Seam} member is this same object, and a second
        #   holder would be a second thing to keep in step.
        # @param library [Skill::Library] the run's ONE skill library -- required, not
        #   defaulted, so nothing here can silently disagree with /help's read of
        #   the same tree
        # @param epic [EpicMount, EpicMount::NoEpic] the finished epic capability --
        #   which epic a chat is in is not this object's question, so a chat outside
        #   one hands over {EpicMount::NoEpic} and nothing below ever asks
        # @param switchboard [#call] a thunk over the run's live {Switchboard} --
        #   the board does not exist yet at construction (the construction cycle
        #   the comment above explains). The live thunk reads nil until
        #   {Wiring#build_agent} has run and is left to raise `NoMethodError`
        #   rather than falling back: a fallback would silently ungate a real
        #   session if the assembly order ever changed. REQUIRED and undefaulted:
        #   the ungated stand-in it once defaulted to would have let a build
        #   assembled without a board gate nothing and say nothing about it.
        # @param askers [Wiring::Askers] the run's ONE {Wiring::Askers} -- who may ask
        #   the human, where an arrival goes, and the directory an answer routes back
        #   through; rides the spawn seam so a child can enrol its own asker
        #   ({Wiring::Askers#enrol}, which also hands back the registration whoever
        #   owns that child's lifetime must `deregister`). REQUIRED and
        #   undefaulted, for `switchboard:`'s reason: a build wired to no queue
        #   parks every human question a child asks.
        # @param isolation [#acquire] the run's ONE {Lain::Isolation} backend, the
        #   same instance {Wiring} hands the {Lain::Supervisor}. Injected rather
        #   than resolved here: a second resolution of one `--isolation` flag is
        #   a second allocator over one project, and neither can see the other's
        #   claims. Defaults to the shared-process baseline for the
        #   direct-construction seams the specs drive, matching what a chat
        #   started without the flag really gets.
        # @param root [String] the PROJECT's root, handed down by {Wiring} -- this
        #   object holds no Project. Read only to resolve `exec` below; a container
        #   MOUNTS it, so a chat started in a subdirectory (or under `--root PATH`)
        #   still shows its commands the project they belong to. REQUIRED rather
        #   than defaulting to `Dir.pwd`, on `spec/lain/project/root_defaults_spec.rb`'s
        #   argument.
        # @param exec [#call] the {Lain::Exec} backend {Lain::Tools::Bash}
        #   becomes a process through. Resolved HERE rather than in {Wiring},
        #   because which transport a capability uses is a fact about the
        #   TOOLSET; injectable all the same, which is what lets a spec pin a
        #   backend the box cannot run. It resolves at CONSTRUCTION, so an
        #   unrecognized `--exec` refuses before {Chronicle#start} pins the
        #   session header -- the refusal-before-journal ordering
        #   {Wiring#fleet_isolation} keeps.
        # @param verdict [#call] `String -> Shell::Verdict::Decision`, the
        #   session's ONE shell verdict, threaded to {BaseTools} and no
        #   further. NOT resolved here, where `exec:` is, and the difference is
        #   the point: which transport a capability uses is a fact about the
        #   TOOLSET, while which programs a project has ruled out is a fact
        #   about the PROJECT -- and the approval ladder consults the same
        #   object. So {Wiring} builds it above both branches and hands the one
        #   instance down each. The default restricts nothing and is resolved
        #   at CALL time, on {BaseTools.build}'s load-order note.
        # @param usage [#call, nil] a thunk resolving to the live Agent's
        #   cumulative {Lain::Usage}, for the main-agent-only
        #   {Lain::Tools::SessionUsage}. Late-bound for `parent:`'s exact reason:
        #   the Agent is built AFTER the Toolset it is handed. nil for the
        #   direct-construction seams, and deliberately NOT a thunk over
        #   {Lain::Usage.zero} -- an unwired build reporting zero tokens is
        #   indistinguishable from an honest fresh run, which is the exact defect
        #   that tool exists to remove.
        # @param handback [Wiring::Handback] how a child's work comes home: the
        #   run's ONE handoff, the same one {Wiring} hands the {Supervisor}.
        #   Defaults to one that only releases, for the direct-construction
        #   seams the specs drive.
        # @option options [Boolean] :auto_approve the ONE key this class reads
        #   for a collaborator, alongside the two `--exec` keys the `exec:`
        #   default reads. Last, after every `@param`, because yard-lint fixes
        #   that order.
        def initialize(backend:, provider:, chronicle:, options:, supervisor:, parent:, journal:, library:, epic:,
                       root:, switchboard:, askers:, usage: nil,
                       verdict: Lain::Shell::Verdict.new, isolation: Lain::Isolation::Null.new,
                       handback: Handback.none,
                       exec: ExecBackend.resolve(options[:exec], image: options[:exec_image], root:))
          @library = library
          @backend = backend
          @options = options
          @exec = exec
          @verdict = verdict
          @epic = epic
          @askers = askers
          @usage = usage
          @seam = spawn_seam(backend:, provider:, parent:, journal:, supervisor:, switchboard:, chronicle:,
                             isolation:, handback:)
        end

        # The run's toolset: the capability floor, plus the child seams and the
        # main-agent-only tools.
        #
        # @param recorder [Lain::Memory::Recorder] the ONE recorder backing
        #   the memory tools for the whole session
        # @param ask_human [Lain::Tools::AskHuman] the reply seam
        #   {Wiring} wired, appended here rather than built here -- the Repl's
        #   replier fiber parks on the same object
        # @return [Lain::Toolset]
        def build(recorder, ask_human:)
          base = capability_floor(recorder)
          @role_spawn = role_spawn_seam(base)
          @docent = Lain::Review::Docent::Answerer.new(spawn: @role_spawn)
          @auto_surface = (Lain::Approval::AutoSurface.new(role_spawn: @role_spawn) if options[:auto_approve])
          @floor = base
          Lain::Toolset.new(base.to_a + [research_subagent(base), ask_human, run_skill, session_usage] + epic.tools)
        end

        # The one Subagent that grants {ISSUE_ORCHESTRATOR}: the floor {#build}
        # made plus the two names only it holds, so no other spawn can build
        # the role. Launched as an actor, so its lifecycle reaches the journal
        # the fleet reads.
        #
        # Its seam is the run's own bar two members: the tool stack its children
        # run behind, copied only to change who the gate is told is asking, and
        # the lane the orchestrator's children lease from and hand back through.
        # That lane is the ISSUE's, and both halves are required: a default
        # would be the chat's, and a child's work would come home onto the
        # chat's branch with no gate in front of it.
        #
        # @param isolation [#acquire, #base] where the orchestrator's children
        #   lease, cut from the issue's own branch
        # @param handoff [#reclaim, #surrender] how their work comes back into
        #   the issue's checkout
        # @param lane [String] prefixes the children's worker ids, so their
        #   anchors cannot meet another lane's in the repository every
        #   worktree shares; e.g. `issue.<slug>.<id>`, refused when git would
        #   not accept it in a ref
        # @return [Lain::Tools::Subagent]
        # @raise [Lain::Isolation::Leases::Lane::Refused]
        def epic_subagent(isolation:, handoff:, lane:)
          raise Lain::Error, "the epic Subagent spawns over the floor #build makes; build the toolset first" if
            @floor.nil?

          issue = seam.with(isolation: issue_leases(isolation, handoff, lane))
          Lain::Tools::Subagent.new(seam: announcing(ISSUE_ORCHESTRATOR.to_s, over: issue),
                                    toolset: orchestrating(issue),
                                    policy: backend.spawn_policy(ISSUE_ORCHESTRATOR), budget: ORCHESTRATOR_BUDGET,
                                    persona: persona(ISSUE_ORCHESTRATOR), max_depth: EPIC_DEPTH, mode: :actor,
                                    announces_as: ISSUE_ORCHESTRATOR.to_s)
        end

        private

        attr_reader :backend, :library, :options, :seam, :epic, :askers

        # The floor, and the session-wide objects that reach it: where a command
        # becomes a process, which programs the project ruled out, and where the
        # bash tool's record of the arm it chose lands. The journal is read off
        # the spawn seam because {Tools::Subagent::Seam} is a Data that stores
        # what it was given -- the member IS the object handed to this
        # constructor, so a second ivar would be a second thing to keep in step.
        def capability_floor(recorder)
          Lain::Toolset.new(BaseTools.build(recorder, exec: @exec, verdict: @verdict, journal: seam.journal))
        end

        # The ONE {Lain::Tools::Subagent::Seam} every child spawn is built
        # over. Both posture axes arrive over the switchboard thunk; see the
        # class comment for why neither may be a captured value.
        #
        # `isolation:` is the run's ONE backend, INJECTED -- the same instance
        # {Wiring} hands the {Supervisor}, never a second resolution of the same
        # flag. Two backends over one project each allocate from per-instance
        # state, so they cannot refuse each other's checkout paths and a service
        # pool without a worker key in it hands one slot out twice; the reason
        # in full is on {Wiring#fleet_isolation}. It is wrapped HERE, and here
        # only, in the {Lain::Isolation::Leases} that owns the spawn
        # lane's worker-id sequence -- one per seam, which is one per run, which
        # is what makes a nested spawn and a sibling fan-out draw from the same
        # count. The backend arrives already journalled, nearest the concrete,
        # and nothing here wraps it again. The same Leases is where the run's
        # handoff reaches a child, so every lease on the spawn lane ends in it.
        #
        # `tool_middleware:` is the parent's own stack, over the same thunk.
        def spawn_seam(backend:, provider:, parent:, journal:, supervisor:, switchboard:, chronicle:, isolation:,
                       handback:)
          Lain::Tools::Subagent::Seam.new(provider:, context_factory: -> { backend.context }, parent:,
                                          tool_middleware: guard(chronicle, switchboard),
                                          journal:, supervisor:, observer: chronicle.observer, askers:,
                                          isolation: Lain::Isolation::Leases.new(backend: isolation,
                                                                                 handoff: handback.handoff,
                                                                                 sync: handback.sync),
                                          permits: PosturePermits.new(board: switchboard))
        end

        # The stack {Wiring#backing} mounts in the parent's tool phase, built again
        # for each child over the same board and the same chronicle: one region
        # ledger, one approval queue, one filter, one layout, one gate policy and
        # one refusal sentence for the whole run. The board thunk is read when a
        # child is built, so a board still nil then raises rather than handing
        # the child a stack over nothing. The child's environment says where its
        # writes land.
        #
        # The child's gate is the privilege-inversion guard: a child gated over
        # anything but its parent's policy could do what its parent must ask to
        # do. It cannot be, because the child's gate comes from the builder that
        # makes the parent's, over the same board.
        def guard(chronicle, switchboard)
          ToolGuard::Spawned.new(chronicle:, board: switchboard, requester: SPAWN_REQUESTER)
        end

        # One seam serves every role: role, policy and persona are chosen PER
        # CALL from the parsed role name and context mode, so what is fixed
        # here is only what they all share.
        def role_spawn_seam(base)
          Lain::Skill::RoleSpawn.new(seam:, toolset: base, slots: library.slots)
        end

        # The in-agent composition primitive: it renders a skill's scaffold
        # back to the SAME agent as a tool_result -- a continuation, not a
        # spawn. Built off the run's ONE library ({Skill::Library#renderer}),
        # so it and the repl's ReplMiddleware compose the same pair
        # #role_spawn_seam frames children with rather than reading the project
        # tree twice more under a claim of "loaded once".
        def run_skill = Lain::Tools::RunSkill.new(renderer: library.renderer)

        # Main-agent-only, and appended HERE rather than added to {BaseTools}:
        # the floor is what a subagent role attenuates FROM, built once and
        # shared, so a thunk over the chat's Agent placed there would make
        # every child report its PARENT's spend as its own.
        def session_usage = Lain::Tools::SessionUsage.new(usage: @usage)

        # The chat default: an attenuated read-only child (schema posture,
        # depth 1), whose :spawn/:message lineage events the observer routes
        # into the session record. `announces_as:` is the human-facing half of
        # the same name -- the tool stays "subagent" because that is what the
        # model calls, so an arrival note says "researcher" instead.
        def research_subagent(base)
          Lain::Tools::Subagent.new(seam: announcing(RESEARCHER.to_s), toolset: base,
                                    policy: backend.spawn_policy(RESEARCHER),
                                    max_depth: 1, announces_as: RESEARCHER.to_s)
        end

        # The floor plus the two names only the orchestrator holds: one spawner
        # over both roles it fans work out to, and the renderer that puts the
        # plan's skill in front of it.
        def orchestrating(issue)
          Lain::Toolset.new(@floor.to_a + [spawning(issue), run_skill])
        end

        # The one spawner the orchestrator holds, offering both roles it fans
        # work out to. Which one a child takes is the orchestrator's choice per
        # call; that the set is these two is not.
        def spawning(issue)
          Lain::Tools::Subagent::Choice.new([IMPLEMENTER, REVIEWER].to_h { |role| [role, spawner(role, issue)] })
        end

        # Depth 1 of its own, so the epic's ceiling lowers nothing and raises
        # nothing, and a child attenuates from the floor, which holds no
        # spawner. Over the issue's seam, so it leases where the orchestrator's
        # children must.
        def spawner(role, issue)
          Lain::Tools::Subagent.new(seam: announcing(role.to_s, over: issue), toolset: @floor,
                                    policy: backend.spawn_policy(role), persona: persona(role), max_depth: 1,
                                    announces_as: role.to_s)
        end

        # What a child is told it is, in its own system prompt: the same role
        # its capabilities were attenuated to, so the two cannot disagree.
        def persona(role)
          Lain::Role::Persona.new(role: Lain::Role::Catalog.fetch(role), slots: library.slots)
        end

        # One worker sequence per epic Subagent, numbered in the issue's own
        # lane, and a self-sync onto the issue's branch, which is the base the
        # children are cut from.
        def issue_leases(isolation, handoff, lane)
          Lain::Isolation::Leases.new(backend: isolation, handoff:,
                                      sync: Lain::Isolation::SelfSync.new(base: isolation.base),
                                      lane: Lain::Isolation::Leases::Lane.named(lane))
        end

        # The same name one rail over: an approval asks the same "who is
        # asking" a question does, so both halves are read off the one word
        # rather than two literals that could drift. Only the name the tool
        # stack asks under is rebound -- every other member of the run's ONE
        # seam is shared, which is the identity the privilege-inversion guard
        # rests on.
        def announcing(requester, over: seam)
          over.with(tool_middleware: over.tool_middleware.with(requester:))
        end
      end
    end
  end
end
