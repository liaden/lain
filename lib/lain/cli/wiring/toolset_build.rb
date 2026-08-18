# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # What capabilities a run holds, and how a child inherits them --
      # {Wiring}'s "assemble a run's collaborators and hand off to the
      # frontend" minus the part that was never about assembly at all. The
      # tell was in the parameter lists: `(backend:, parent:, journal:)` was
      # threaded verbatim through three private methods, and a triple passed
      # identically at every call is state an object is missing, not
      # arguments. It is injected once, here, and the seam methods read it.
      #
      # T23 took the argument one step further, where it had always pointed: the
      # six a child spawn is built over used to be assembled into a Hash by a
      # private `#child_seam_kwargs` and splatted into both child seams. They are
      # now one {Lain::Tools::Subagent::Seam}, built in the constructor, which is
      # why five of this class's ivars are gone -- provider, chronicle,
      # supervisor, journal, and the parent handle were only ever held to fill
      # that Hash.
      #
      # The set is layered, and the layering is the policy. {BaseTools} is the
      # capability floor, and it is ALSO the union a child attenuates from --
      # so the same `base` is what {Skill::RoleSpawn} and {Tools::Subagent}
      # are handed, while `ask_human`, {Tools::RunSkill} and the epic's own
      # tools are appended AFTER, main-agent-only.
      #
      # Two of those three are main-agent-only because the CONVERSATION is: a
      # child must not render a skill scaffold back into a conversation that is
      # not the one the human is having, and {Tools::RequestReview} PARKS
      # holding an artifact's baton, which belongs to the epic the human is
      # watching. `ask_human` was on that list for a third reason, and T10
      # reversed it: a child may now ask the human. What it must not inherit is
      # the PARENT's asker -- whose questions would be attributed to the
      # parent's chain and whose promise the parent's {AskHuman::Outstanding}
      # holds -- so the floor still carries none, and {Tools::Subagent::
      # ChildBuilder} enrols one per child on the run's {Askers}, over the
      # child's own handle. The layering is unchanged; what changed is that a
      # capability the floor withholds is now GRANTED at the spawn.
      #
      # {#role_spawn} and {#auto_surface} are readable only once {#build} has
      # run, because they are things the build DISCOVERS rather than things it
      # is told -- Wiring delegates both, and its own callers (the Repl's
      # command surface) read them well after the toolset exists.
      class ToolsetBuild
        # == Why BOTH seam axes are delegators over a thunk, not values
        #
        # {Tools::Subagent::Seam} is a frozen `Data` built ONCE, here, and the
        # run's {Switchboard} does not exist yet when it is built: the board
        # requires the session's base `toolset:` (T10), and that toolset is what
        # {#build} RETURNS. Asking for the board here is a construction cycle,
        # not an argument that was forgotten. So the board arrives as a thunk
        # read at call time, and each axis reads its own switch through it.
        #
        # That would be required even without the cycle. A captured
        # `mode_switch.posture.permits` freezes the child's capability rule at
        # session start, so a mid-session `/mode plan` would journal, repaint
        # the HUD, attenuate the parent -- and leave every child holding `bash`,
        # silently, which is the same failure as not gating at all. A captured
        # `policy_switch` has the identical shape one axis over. This is the
        # {Context::ModelSwitch} / {Approval::PolicySwitch} rule: a live change
        # is a slot the holder already has, never a setter on the holder.
        #
        # The three are separate objects because they read separate slots and
        # answer separate ducks -- one `include?(name)`, one
        # `call(effect, context)`, one `gates?(effect)`. Each is exactly the one
        # message its consumer asks, which is what keeps them delegators rather
        # than second implementations of a Permits, a policy and a classifier.
        #
        # ⚠️ The axes do NOT all have the same liveness, and the difference is
        # visible: `gate_policy` and `sensitivity` are consulted per CALL, so a
        # change reaches a running child's next tool call, while `permits` is
        # consulted per SPAWN, so a child already running keeps the plain
        # {Toolset} it was rendered. See {Tools::Subagent::ChildBuilder#permitted}
        # for what that means for an in-flight `:actor` under `/mode plan`.
        PosturePermits = Data.define(:board) do
          def include?(tool_name) = board.call.mode_switch.posture.permits.include?(tool_name)
        end

        # What a child announces itself as at the approval gate when the spawn
        # bound no more specific name. The tool's own default `name`, so a park
        # is at least separable from the human's own agent
        # ({Approval::Queue}'s `requester:`) without claiming an identity the
        # spawn never took.
        SPAWN_REQUESTER = "subagent"

        # The gate half of the same late binding: {Effect::Handler::Gate}'s
        # policy duck, answering through whichever policy the board's ONE
        # {Approval::PolicySwitch} currently holds -- so `/yolo` and a posture
        # flip both reach a child's next tier-3 call, exactly as they reach the
        # parent's.
        #
        # It is also the one object on a child's gate path that knows WHICH
        # child it is gating, so it is where the requester is bound (T9): the
        # board, the switch and the ladder are all session-wide and cannot tell
        # a fleet apart. The name rides the context
        # ({Approval::PolicySwitch::Requested}) rather than a new parameter,
        # because the parent's gate and the child's must keep resolving the
        # SAME policy through the SAME two-argument duck -- that identity is
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
        # points -- one decides, one selects what gets decided.
        #
        # Reading it through the board rather than capturing the policy is what
        # makes the privilege inversion unrepresentable: a child's gate and its
        # parent's resolve the SAME board and therefore the same one policy, so
        # they cannot be wired to disagree about which paths are sensitive.
        LiveSensitivity = Data.define(:board) do
          def gates?(effect) = board.call.sensitivity.gates?(effect)
          def denial(effect) = board.call.sensitivity.denial(effect)
        end

        # A frozen {Lain::Mode} answers `#posture` exactly as {Mode::Switch}
        # does, and `#posture` is the whole of what {PosturePermits} asks -- so
        # the Null below stands in for a switch with a real value rather than
        # with a fake duck. `accept_edits` because it is the ladder's default
        # and its {Mode::Posture::Permits} is `All`: a build with no live board
        # attenuates nothing, which is what "no posture was ever bound here"
        # has to mean.
        UNSWITCHED = Lain::Mode.new(posture: :accept_edits)
        private_constant :UNSWITCHED

        # The board a directly-constructed build runs under: children are
        # ungated and unattenuated, byte-for-byte what every spawn did before
        # T11 gated them.
        #
        # This is for the direct-construction seams the specs drive, and it is
        # NOT a sanctioned production state: the exe always passes a thunk over
        # the run's real {Switchboard}, because a session whose parent gates
        # `bash` while its children do not is the security property this chunk
        # claims and would not have. `policy_switch` resolves inside the method
        # body on purpose -- `lain.rb` requires `lain/cli` fifteen entries
        # BEFORE `lain/tools`, so an eager `Tools::Subagent::UNGATED` in this
        # class body is a hard NameError at load, the same debt
        # `mode/resolution.rb` records and defers the same way.
        NoSwitchboard = Class.new do
          def policy_switch = Lain::Tools::Subagent::UNGATED
          def mode_switch = UNSWITCHED
          def sensitivity = Lain::Sensitivity::Policy::Null.instance

          def inspect = "Lain::CLI::Wiring::ToolsetBuild::NoSwitchboard"
          alias_method :to_s, :inspect
        end.new.freeze

        # The role the chat's own subagent spawns, named ONCE: what it may do
        # (its `only`-set, through {Backend#spawn_policy}) and what a human is
        # told it is (its arrival note) are two readings of one fact, and two
        # literals is how they drift.
        RESEARCHER = :researcher

        # The repl-phase role-spawn seam a `@role/skill` line folds through
        # (nil until {#build}), the opt-in third approval surface over it (nil
        # without --auto-approve, so the Repl wires nothing extra by default),
        # and T24's docent ANSWERER.
        #
        # The answerer and not a {Review::Docent}: a docent is keyed to a
        # changeset and a thread pane, and neither exists at toolset-build time
        # -- what a RUN holds is the capability to spawn the role, which is what
        # this hands whichever card opens a review. DELETABLE with the docent;
        # see `review.rb` for the rest of that map.
        attr_reader :role_spawn, :auto_surface, :docent

        # `provider:` is INJECTED rather than resolved here: it is the run's
        # spooled provider, and {Wiring} builds the only other one. Two
        # construction sites would be two answers to "which spool do round
        # trips tee into", and the pairing is not allowed to come apart. It, the
        # chronicle's observer, the supervisor, the journal and the parent handle
        # are read once, into the one spawn {Lain::Tools::Subagent::Seam} both
        # child seams travel over.
        #
        # `library:` is injected for the same reason and is REQUIRED, not
        # defaulted: the run has ONE {Skill::Library}, and a default here would
        # be a second read of the same tree that nothing would ever notice
        # disagreeing with /help's. It arrived as a `catalog:` keyword beside a
        # `backend.slots` reach-through until T40 named the pair -- one keyword
        # cannot be half-forgotten, which two could.
        #
        # `epic:` is injected for the third time on the same rule, and it is
        # REQUIRED: which epic a chat is in is not this object's question, and
        # the `(home:, review:, notes:)` triple {Lain::Tools::RequestReview}
        # takes carries an invariant between its members (ONE Review, in both
        # places) that only {EpicMount} can keep. What arrives here is a finished
        # capability provider, exactly as `provider:` and `library:` do, and what
        # is asked of it is one message -- so a chat outside an epic hands over
        # {EpicMount::NoEpic} and no line below asks whether there is an epic.
        #
        # `switchboard:` is a THUNK over the run's live switches, and the seam
        # reads two of them (T11): the {Approval::PolicySwitch} a child's tier-3
        # call must pass, and the {Mode::Switch} that says which capabilities a
        # child may hold at all. A thunk and not the board itself, because the
        # board does not exist yet -- see the two delegators above for the
        # construction cycle that forces it. It is the run's ONE board, injected
        # for `provider:`'s exact reason: a second Switchboard built here would
        # be a second answer to "what mode is this session in", and the two
        # would disagree the moment either was flipped.
        #
        # The live thunk (`-> { @switchboard }`, wiring.rb) reads nil until
        # {Wiring#build_agent} has run, and that is deliberately left to raise
        # `NoMethodError` rather than falling back to {NoSwitchboard}: a
        # fallback would silently ungate a real session if the assembly order
        # ever changed, which is the one failure this card exists to remove. No
        # spawn can reach it in practice -- a child is spawned from a tool
        # dispatch, which is turns after the Agent was built.
        #
        # It is DEFAULTED where `library:` and `epic:` are required, and the
        # default is a thunk over {NoSwitchboard}: children then behave exactly
        # as they did before they were gated at all. That is a deliberately
        # narrow escape hatch for the direct-construction seams the specs
        # drive, not a sanctioned production state.
        #
        # `askers:` is the run's ONE {Wiring::Askers} -- who may ask the human,
        # where an arrival goes, and the directory an answer is routed back
        # through (T11) -- and it rides the spawn seam, because T10 is what
        # made a CHILD able to ask. One object for the whole run, for
        # `provider:`'s exact reason: a second one built for children would be
        # a second answer to "who is holding this question", and the human
        # drains only one queue. Everything a spawn needs from it is one
        # message -- {Wiring::Askers#enrol} hands back the child's own asker
        # and the {Tools::AskHuman::Directory::Registration} whoever owns that
        # child's lifetime must `deregister`.
        #
        # Defaulted for `switchboard:`'s exact reason and with the same
        # caveat: {Wiring::Askers.unwired} is the direct-construction seam the
        # specs drive, where a child's question would reach no queue and no
        # desktop. The exe always passes the run's own.
        #
        # @param backend [Backend] the run's provider/model choice ({CLI::Backend}) --
        #   read here for `backend.context` (the child seam's context factory) and
        #   `backend.spawn_policy` (the researcher role-spawn's `only`-set)
        # @param provider [Provider] the run's ONE spooled provider ({Wiring} builds
        #   the only other one) -- injected rather than resolved here, so both
        #   construction sites agree on which spool round trips tee into
        # @param chronicle [Chronicle] read once for `chronicle.observer`, folded
        #   into the one spawn {Lain::Tools::Subagent::Seam} both child seams
        #   travel over
        # @param options [Hash] the parsed CLI options; `:auto_approve` gates whether
        #   {#auto_surface} is built at all (nil without the flag, so the Repl wires
        #   nothing extra by default)
        # @param supervisor [Supervisor] the OM-6 supervisor a spawned actor adopts
        #   its isolation lease from and runs under ({Tools::Subagent#supervisor});
        #   read once, alongside `parent:` and `journal:`, into the one spawn seam
        # @param parent [#call] a thunk reading the live parent Timeline --
        #   the subagent tool reads the head at SPAWN time, so this must stay
        #   late-bound.
        # @param journal [#<<] where a spawned child's lifecycle events land
        #   ({Tools::Subagent#journal_lifecycle}); read once, with `parent:` and
        #   `supervisor:`, into the one spawn seam
        # @param library [Skill::Library] the run's ONE skill library -- required, not
        #   defaulted, so nothing here can silently disagree with /help's read of
        #   the same tree
        # @param epic [EpicMount, EpicMount::NoEpic] the finished epic capability --
        #   which epic a chat is in is not this object's question, so a chat outside
        #   one hands over {EpicMount::NoEpic} and nothing below ever asks
        # @param switchboard [#call] a thunk over the run's live {Switchboard} -- the
        #   board does not exist yet at construction (the construction cycle the
        #   comment above explains); defaults to a thunk over {NoSwitchboard} for
        #   the direct-construction seams the specs drive
        # @param askers [Wiring::Askers] the run's ONE {Wiring::Askers} -- who may ask
        #   the human, where an arrival goes, and the directory an answer routes back
        #   through; rides the spawn seam so a child can enrol its own asker
        #   ({Wiring::Askers#enrol}). Defaults to {Wiring::Askers.unwired} for the
        #   direct-construction seams the specs drive.
        # @option options [Boolean] :auto_approve the ONE key this class reads --
        #   everything else in the parsed options belongs to somebody further up.
        #   Last, after every `@param`, because yard-lint fixes that order.
        def initialize(backend:, provider:, chronicle:, options:, supervisor:, parent:, journal:, library:, epic:,
                       switchboard: -> { NoSwitchboard }, askers: Askers.unwired)
          @library = library
          @backend = backend
          @options = options
          @epic = epic
          @askers = askers
          @seam = spawn_seam(backend:, provider:, parent:, journal:, supervisor:, switchboard:,
                             observer: chronicle.observer)
        end

        # The run's toolset: the capability floor, plus the child seams and
        # the two main-agent-only tools.
        #
        # @param recorder [Lain::Memory::Recorder] the ONE recorder backing
        #   the memory tools for the whole session
        # @param ask_human [Lain::Tools::AskHuman::Notifying] the reply seam
        #   {Wiring} wired, appended here rather than built here -- the Repl's
        #   replier fiber parks on the same object
        # @return [Lain::Toolset]
        def build(recorder, ask_human:)
          base = Lain::Toolset.new(BaseTools.build(recorder))
          @role_spawn = role_spawn_seam(base)
          @docent = Lain::Review::Docent::Answerer.new(spawn: @role_spawn)
          @auto_surface = (Lain::Approval::AutoSurface.new(role_spawn: @role_spawn) if options[:auto_approve])
          Lain::Toolset.new(base.to_a + [research_subagent(base), ask_human, run_skill] + epic.tools)
        end

        private

        attr_reader :backend, :library, :options, :seam, :epic, :askers

        # The ONE {Lain::Tools::Subagent::Seam} every child spawn is built
        # over, in a method of its own because the constructor above is now
        # "read the run's collaborators" and this is "assemble what a child is
        # built from" -- two jobs, and MethodLength said so when the eleventh
        # line landed. Both posture axes arrive as delegators over the
        # switchboard thunk; see the class comment for why neither may be a
        # captured value.
        def spawn_seam(backend:, provider:, parent:, journal:, supervisor:, switchboard:, observer:)
          Lain::Tools::Subagent::Seam.new(provider:, context_factory: -> { backend.context }, parent:,
                                          journal:, supervisor:, observer:, askers:,
                                          gate_policy: LivePolicy.new(board: switchboard),
                                          permits: PosturePermits.new(board: switchboard),
                                          sensitivity: LiveSensitivity.new(board: switchboard))
        end

        # One seam serves every role: the role, policy, and persona are chosen
        # PER CALL from the parsed role name and context mode, so what is
        # fixed here is only what they all share. `slots:` is the session's
        # rendered-persona source -- the library's half, loaded once.
        def role_spawn_seam(base)
          Lain::Skill::RoleSpawn.new(seam:, toolset: base, slots: library.slots)
        end

        # The in-agent composition primitive: it renders a skill's scaffold
        # back to the SAME agent as a tool_result -- a continuation, not a
        # spawn. Built off the run's ONE library, so it and the repl's
        # ReplMiddleware compose the same pair #role_spawn_seam frames children
        # with. It called `ReplMiddleware.renderer` argument-less until T15,
        # which read the project tree twice more -- a claim of "loaded once"
        # that the loads did not keep; the shared composition seam that fixed
        # then lives on the library now ({Skill::Library#renderer}).
        def run_skill = Lain::Tools::RunSkill.new(renderer: library.renderer)

        # The chat default: an attenuated read-only child (schema posture,
        # depth 1). The observer routes its :spawn/:message lineage events
        # into the session record, exactly as ask_human's Q/A goes.
        #
        # `announces_as:` is the human-facing half of the same name (T10): the
        # tool stays "subagent" because that is what the model calls, and its
        # child is announced as the role it IS, so an arrival note and a
        # desktop notification say "researcher" rather than the tool's name.
        def research_subagent(base)
          Lain::Tools::Subagent.new(seam: announcing(RESEARCHER.to_s), toolset: base,
                                    policy: backend.spawn_policy(RESEARCHER),
                                    max_depth: 1, announces_as: RESEARCHER.to_s)
        end

        # The same name one rail over (T9). `announces_as:` already says what a
        # human is TOLD is asking when this child puts a QUESTION to them; an
        # approval is the same question, so both halves are read off the one
        # word rather than from two literals that could drift. Only the gate
        # policy is rebound -- every other member of the run's ONE seam is
        # shared, which is the identity the privilege-inversion guard rests on.
        def announcing(requester) = seam.with(gate_policy: seam.gate_policy.with(requester:))
      end
    end
  end
end
