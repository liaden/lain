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
        # == Why both seam axes are delegators over a thunk, not values
        #
        # {Tools::Subagent::Seam} is a frozen `Data` built ONCE, here, and the
        # run's {Switchboard} does not exist yet: the board requires the base
        # `toolset:` that {#build} RETURNS. Asking for the board here is a
        # construction cycle, not an argument that was forgotten, so it arrives
        # as a thunk read at call time.
        #
        # The cycle is not the only reason. A captured
        # `mode_switch.posture.permits` freezes the child's capability rule at
        # session start, so a mid-session `/mode plan` would journal, repaint
        # the HUD, attenuate the parent -- and leave every child holding
        # `bash`, silently, which is the same failure as not gating at all.
        # The {Context::ModelSwitch} / {Approval::PolicySwitch} rule: a live
        # change is a slot the holder already has, never a setter.
        #
        # Three delegators and not one because they read separate slots and
        # answer separate ducks -- `include?`, `call(effect, context)`,
        # `gates?` -- and their liveness differs: `gate_policy` and
        # `sensitivity` are consulted per CALL, `permits` per SPAWN, so a child
        # already running keeps the plain {Toolset} it was rendered
        # ({Tools::Subagent::ChildBuilder#permitted}).
        PosturePermits = Data.define(:board) do
          def include?(tool_name) = board.call.mode_switch.posture.permits.include?(tool_name)
        end

        # What a child announces itself as at the approval gate when the spawn
        # bound no more specific name -- the tool's own default `name`, so a
        # park is at least separable from the human's own agent
        # ({Approval::Queue}'s `requester:`) without claiming an identity the
        # spawn never took.
        SPAWN_REQUESTER = "subagent"

        # The gate half of the same late binding: {Effect::Handler::Gate}'s
        # policy duck, answering through whichever policy the board's ONE
        # {Approval::PolicySwitch} currently holds, so a `/mode` posture flip
        # reaches a child's next tier-3 call.
        #
        # It is also the one object on a child's gate path that knows WHICH
        # child it is gating, so it is where the requester is bound -- the
        # board, the switch and the ladder are all session-wide and cannot tell
        # a fleet apart. The name rides the context
        # ({Approval::PolicySwitch::Requested}) rather than a new parameter,
        # because the parent's gate and the child's must keep resolving the
        # SAME policy through the SAME two-argument duck, and that identity is
        # what makes the privilege inversion unrepresentable.
        LivePolicy = Data.define(:board, :requester) do
          def initialize(board:, requester: SPAWN_REQUESTER) = super

          def call(effect, context)
            board.call.policy_switch.call(effect, Lain::Approval::PolicySwitch::Requested.new(context, requester))
          end
        end

        # The PATH half of the same gate, over the same thunk. Not folded into
        # {LivePolicy}: the gate asks its policy `call(effect, context)` and its
        # sensitivity `gates?(effect)`, two different ducks at two different
        # points -- one decides, one selects what gets decided. Read through
        # the board rather than captured, so a child's gate and its parent's
        # resolve the same one policy and cannot be wired to disagree about
        # which paths are sensitive.
        LiveSensitivity = Data.define(:board) do
          def gates?(effect) = board.call.sensitivity.gates?(effect)
          def denial(effect) = board.call.sensitivity.denial(effect)
        end

        # A frozen {Lain::Mode} answers `#posture` exactly as {Mode::Switch}
        # does, which is the whole of what {PosturePermits} asks -- so the Null
        # below stands in with a real value rather than a fake duck.
        # `accept_edits` because its {Mode::Posture::Permits} is `All`: a build
        # with no live board attenuates nothing, which is what "no posture was
        # ever bound here" has to mean.
        UNSWITCHED = Lain::Mode.new(posture: :accept_edits)
        private_constant :UNSWITCHED

        # The board a directly-constructed build runs under: children ungated
        # and unattenuated, byte-for-byte what every spawn did before children
        # were first gated. For the direct-construction seams the specs drive,
        # and NOT a sanctioned production state -- the exe always passes a
        # thunk over the run's real {Switchboard}.
        #
        # `policy_switch` resolves inside the method body on purpose: `lain.rb`
        # requires `lain/cli` fifteen entries BEFORE `lain/tools`, so an eager
        # `Tools::Subagent::UNGATED` in this class body is a hard NameError at
        # load -- the same debt `mode/resolution.rb` records and defers the
        # same way.
        NoSwitchboard = Class.new do
          # The one value {ToolGuard} reads. One ledger, for {Switchboard}'s
          # reason; no queue, which the guard reads as a run nobody attends --
          # every region is released, byte-for-byte what a child read before
          # children were guarded; and no test layout, so nothing is refused.
          # `lain/cli` loads `cli/tool_guard` before `cli/wiring`, so this may
          # be built with the class.
          attr_reader :guard_inputs

          def initialize
            super
            @guard_inputs = ToolGuard::Inputs.new(ledger: Lain::Sensitivity::Ledger.new, approvals: nil,
                                                  sensitivity: Lain::Sensitivity::Policy::Null.instance,
                                                  test_layout: Lain::Middleware::GuardTestLayout::Run.undeclared)
          end

          def approvals = nil
          def policy_switch = Lain::Tools::Subagent::UNGATED
          def mode_switch = UNSWITCHED
          def sensitivity = Lain::Sensitivity::Policy::Null.instance
          # A board that was never wired knows nothing about who is attached,
          # so a child gated by {UNGATED} reads the sentence
          # {Effect::Handler::Gate} produces on its own. Resolved in the body
          # for `policy_switch`'s load-order reason.
          def denial = Lain::Effect::Handler::Gate::DENIAL

          def inspect = "Lain::CLI::Wiring::ToolsetBuild::NoSwitchboard"
          alias_method :to_s, :inspect
        end.new.freeze

        # The role the chat's own subagent spawns, named ONCE: what it may do
        # (its `only`-set, through {Backend#spawn_policy}) and what a human is
        # told it is (its arrival note) are two readings of one fact, and two
        # literals is how they drift.
        RESEARCHER = :researcher

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
        #   session if the assembly order ever changed. Defaults to a thunk over
        #   {NoSwitchboard} for the direct-construction seams the specs drive.
        # @param askers [Wiring::Askers] the run's ONE {Wiring::Askers} -- who may ask
        #   the human, where an arrival goes, and the directory an answer routes back
        #   through; rides the spawn seam so a child can enrol its own asker
        #   ({Wiring::Askers#enrol}, which also hands back the registration whoever
        #   owns that child's lifetime must `deregister`). Defaults to
        #   {Wiring::Askers.unwired} for the direct-construction seams the specs drive.
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
                       root:, switchboard: -> { NoSwitchboard }, askers: Askers.unwired, usage: nil,
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
        # @param ask_human [Lain::Tools::AskHuman::Notifying] the reply seam
        #   {Wiring} wired, appended here rather than built here -- the Repl's
        #   replier fiber parks on the same object
        # @return [Lain::Toolset]
        def build(recorder, ask_human:)
          base = capability_floor(recorder)
          @role_spawn = role_spawn_seam(base)
          @docent = Lain::Review::Docent::Answerer.new(spawn: @role_spawn)
          @auto_surface = (Lain::Approval::AutoSurface.new(role_spawn: @role_spawn) if options[:auto_approve])
          Lain::Toolset.new(base.to_a + [research_subagent(base), ask_human, run_skill, session_usage] + epic.tools)
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
        # over. Both posture axes arrive as delegators over the switchboard
        # thunk; see the class comment for why neither may be a captured value.
        #
        # `denial:` -- what a refused call is REPORTED as -- is a bare thunk
        # rather than a fourth delegator Data, on `context_factory`'s
        # precedent: what a child needs back is a String, not an object
        # answering a duck. It rides the same board thunk for the same
        # privilege-inversion reason the other three do -- a child told the
        # generic "approval denied" in an unattended session reads a human's no
        # and retries a call nobody can ever approve, for the life of the run.
        # `isolation:` is the run's ONE backend, INJECTED -- the same instance
        # {Wiring} hands the {Supervisor}, never a second resolution of the same
        # flag. Two backends over one project each allocate from per-instance
        # state, so they cannot refuse each other's checkout paths and a service
        # pool without a worker key in it hands one slot out twice; the reason
        # in full is on {Wiring#fleet_isolation}. It is wrapped HERE, and here
        # only, in the {Lain::Tools::Subagent::Leases} that owns the spawn
        # lane's worker-id sequence -- one per seam, which is one per run, which
        # is what makes a nested spawn and a sibling fan-out draw from the same
        # count. The backend arrives already journalled, nearest the concrete,
        # and nothing here wraps it again. The same Leases is where the run's
        # handoff reaches a child, so every lease on the spawn lane ends in it.
        #
        # `tool_middleware:` is the parent's own guard, over the same thunk.
        def spawn_seam(backend:, provider:, parent:, journal:, supervisor:, switchboard:, chronicle:, isolation:,
                       handback:)
          Lain::Tools::Subagent::Seam.new(provider:, context_factory: -> { backend.context }, parent:,
                                          tool_middleware: guard(chronicle, switchboard),
                                          journal:, supervisor:, observer: chronicle.observer, askers:,
                                          isolation: Lain::Tools::Subagent::Leases.new(backend: isolation,
                                                                                       handoff: handback.handoff,
                                                                                       sync: handback.sync),
                                          gate_policy: LivePolicy.new(board: switchboard),
                                          permits: PosturePermits.new(board: switchboard),
                                          sensitivity: LiveSensitivity.new(board: switchboard),
                                          denial: -> { switchboard.call.denial })
        end

        # The stack {AgentBuild} mounts in the parent's tool phase, built again
        # for each child over the same board and the same chronicle: one region
        # ledger, one approval queue, one filter and one layout for the whole
        # run. The board thunk is read when a child is built, so a board still
        # nil then raises rather than handing the child a guard over nothing.
        # The child's environment says where its writes land.
        def guard(chronicle, switchboard)
          ->(worker_env) { ToolGuard.child_stack(chronicle, switchboard.call, worker_env) }
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

        # The same name one rail over: an approval asks the same "who is
        # asking" a question does, so both halves are read off the one word
        # rather than two literals that could drift. Only the gate policy is
        # rebound -- every other member of the run's ONE seam is shared, which
        # is the identity the privilege-inversion guard rests on.
        def announcing(requester) = seam.with(gate_policy: seam.gate_policy.with(requester:))
      end
    end
  end
end
