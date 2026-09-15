# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/module/delegation"
require "delegate"

module Lain
  module CLI
    # The live switches a session's commands flip:
    #
    # * ONE {Approval::PolicySwitch} the Gate holds for the whole session --
    #   a mode flip re-binds the delegate inside it, Gate stays
    #   construction-fixed. An attended session's {Approval::Queue} is the
    #   parked list `/approve` drains, and the {Approval::Escalation} ladder
    #   OVER it is what `ask` approval resolves to, so the deterministic rungs
    #   answer first and the queue is where a call lands when they abstain. An
    #   unattended one wires NO queue ({#approvals} is nil then).
    # * ONE {Context::ModelSwitch} the main agent's Context reads at render
    #   time -- `/model` writes it, {#graft} installs it.
    # * ONE {Mode::Switch} holding the session's scope, approval and layers --
    #   `/mode` writes it, the prompt and the HUD read it.
    #
    # The toolset is not among them. A mode never changes what the model is
    # shown, so the run's one set is what {#toolset} answers for its whole life
    # and the tool block a prompt cache keys on never moves under a flip.
    #
    # Nothing here re-states what a mode MEANS. This class picks the starting
    # {Mode}; {Mode::Resolution} answers the gate policy that mode implies, for
    # the starting mode and for every flip after it.
    #
    # Every switch journals its flips to the SAME journal approval decisions
    # land in: on a study bench "who flipped what, when" is evidence.
    class Switchboard
      # All three slots live HERE rather than in {Wiring} for a mechanical
      # reason: each needs the run's `journal:`, and Wiring's only source for
      # one is `chronicle.record_journal`, which OPENS a file per call
      # (/dev/null under --no-journal). This class resolves that journal
      # exactly once and builds all of them over it.
      #
      # `ladder` and `sensitivity` sit beside the switches without being ones:
      # neither has a writer at all, so exposing them hands out the reading --
      # which rungs are in force in what order, which paths this session gates
      # -- and no authority. `ladder` is never nil and never a different KIND
      # of thing (a session with nobody to ask gets an {Approval::Escalation}
      # of one refusing {Unattended} rung), so no caller writes
      # `if board.ladder`. `sensitivity` is read off {#guard_inputs} by the
      # gate {ToolGuard} builds for the parent and for every child: ONE policy,
      # so the two cannot disagree.
      #
      # `ledger` is the opposite kind of slot: deliberately mutable run state,
      # where the reading IS the authority to release. It is exposed because
      # the masking arm and the approval arm must hold the SAME one, and two
      # half-wirings would give the run two ledgers and a release control that
      # silently releases nothing. Constructed for a queueless session too: the
      # approval level decides who is asked, not whether the run has somewhere to
      # record an answer.
      attr_reader :approvals, :ladder, :policy_switch, :model_switch, :mode_switch, :toolset

      # Who a mode the session STARTED in is attributed to: the command line
      # that launched it, which no surface of the running session can be.
      LAUNCH_SURFACE = "launch"

      # The wiring entry: resolves the journal the chronicle carries, then
      # builds the switches over it. `--auto-approve` is read here and only
      # here, as the starting mode's `auto_approve` layer: the surface that
      # decides is {CLI::Wiring::ToolsetBuild}'s, built for every run and
      # answering to that layer, so the flag and `/mode +auto_approve` are one
      # switch and the prompt's lighter shows whichever of them turned it on.
      #
      # `toolset:` is the run's capability set, held for the whole session.
      #
      # `rules:` and `sensitivity:` are two vocabularies and never one. `rules:`
      # is APPROVAL -- remembered answers about call SHAPES, which grant. The
      # other is the PATH classifier, which restricts and grants nothing.
      # Neither may be passed where the other is expected.
      #
      # @param chronicle [#record_journal] the run's chronicle; its journal is
      #   what the switches record onto
      # @param options [Hash] the CLI's parsed surface flags
      # @param model [String] the model in force until the first /model
      # @param toolset [Lain::Toolset] the run's capability set
      # @param rules [Enumerable<Approval::Rule>] the deterministic rung's rules,
      #   which for a live session is {Project::Consent#rules} -- the remembered
      #   answers a CONSENTED root is allowed to contribute
      # @param sensitivity [#gates?] which PATHS this session gates, built by
      #   {CLI::Wiring} over the resolved {Project} and that project's
      #   `[sensitivity]` table. Defaulted to the same Null `new` defaults to,
      #   so the direct-construction seams a spec drives are unchanged
      # @param approving [#call] composes the rules rung's chain, on `new`'s terms
      # @param classifiers [#call] the triage rung's `cwd -> #classify` factory,
      #   on `new`'s terms
      # @param verdict [#call] the triage rung's shell verdict, on `new`'s terms
      # @param spike [#acquire, #reminder, #release] where plan scope leases, on `new`'s terms
      # @param test_layout [Middleware::GuardTestLayout::Run] the session's
      #   one test layout run. REQUIRED here: a chat with no layout decision
      #   behind it is a mis-wire, not a default
      # @option options [Boolean] :non_interactive no human is at this
      #   session's terminal
      # @option options [Boolean] :auto_approve the session starts with the
      #   `auto_approve` layer on. These two are the only flags this entry
      #   reads off `options`
      # @return [Switchboard]
      def self.for(chronicle:, options:, model:, toolset:, test_layout:, rules: [], approving: REMEMBERED,
                   sensitivity: Sensitivity::Policy::Null.instance,
                   classifiers: Approval::Escalation::Triage::AnyPath.new,
                   verdict: Lain::Shell::Verdict.new, spike: Scoping::NOWHERE)
        new(journal: chronicle.record_journal, model:, toolset:, rules:, approving:, sensitivity:, classifiers:,
            verdict:, test_layout:, spike:, attended: !options[:non_interactive],
            layers: options[:auto_approve] ? [:auto_approve] : [])
      end

      # The rules rung's chain when nothing composes one: the remembered
      # answers alone, whatever factory a worker is judged by.
      REMEMBERED = ->(rules, _classifiers) { rules }

      # What the tool stack is built over, as ONE value: the ledger and the
      # path policy described above, the approval queue, the session's one
      # test layout run, the gate's one policy switch and the policy each
      # worker is asked through ({#policy_for}), and what a refused call is
      # reported as ({#denial}). The parent's stack and every child's read it,
      # so they hold one of each and say an absence once.
      attr_reader :guard_inputs

      delegate :ledger, :sensitivity, :test_layout, to: :guard_inputs

      # @param journal [#record] where flips and approval decisions land
      # @param model [String] the model in force until the first /model
      # @param toolset [Lain::Toolset] the run's capability set, which the
      #   rules rung reads a call's tier off. Required, with no empty-set
      #   default: a board built without one would show the model no tools at
      #   all, and a forgotten collaborator must be an ArgumentError here, not a
      #   mystery one turn on.
      # @param rules [Enumerable<Approval::Rule>] consulted by the ladder's
      #   deterministic `rules` rung, ahead of the queue and ahead of any human.
      #   EMPTY by default, which abstains on everything: filling it is
      #   {Project::Consent}'s decision, because only a CONSENTED root's answers
      #   may grant authority.
      # @param approving [#call] `(rules, classifiers) -> rules`, the chain the
      #   rules rung consults over a factory: {REMEMBERED} by default, and
      #   {CLI::Wiring::BoardBuild.approving} in a real chat, which appends the
      #   rule that can approve a command. Handed over as a composition rather
      #   than a composed chain, because a leased worker's chain is composed
      #   again over the factory its own checkout answers.
      # @param sensitivity [#gates?] which PATHS this session gates, whatever
      #   the tool's own tier. {Sensitivity::Policy::Null} by default, so a
      #   session that resolved no project root behaves byte-for-byte as it did
      #   before this axis existed.
      # @param classifiers [#call] `cwd -> #classify`, the factory the ladder's
      #   triage rung anchors a bash argv on. THE THIRD VOCABULARY on this
      #   board, and its resemblance to `sensitivity:` is a trap: that one is
      #   the run's path BOUNDARY, asked `gates?` about a path a tool already
      #   resolved; this one is asked for a FRESH classifier per gated command,
      #   because a command names its own working directory.
      #   {Approval::Escalation::Triage::AnyPath} by default, which protects
      #   nothing. {CLI::Wiring::BoardBuild::Classifiers} is what a real chat
      #   passes, and board_build_spec asserts that IDENTITY rather than the
      #   behaviour: dropping the argument at the one call site restores this
      #   default and disarms the rung with a fully green suite, which is how
      #   the argv check came to be dead for two chunks.
      # @param verdict [#call] `String -> Shell::Verdict::Decision`, the
      #   session's ONE shell verdict, handed on to the ladder's triage rung.
      #   THE SAME INSTANCE {Lain::Tools::Bash} chooses its arm with: {Wiring}
      #   builds it from the project's `[shell]` table and gives it to the
      #   toolset and to this board, so the verdict a record names and the
      #   verdict a command ran under are one object rather than two agreeing
      #   parses. Its exclusion table is also the only thing on this ladder
      #   that can DENY on the model's own words.
      #
      #   Both approval levels consult it: `ask` and `auto` share the
      #   deterministic rungs and differ only below them, so the exclusion
      #   table denies under `/mode auto` exactly as it does under `ask`. An
      #   unattended session's `ask` is the one-rung {Unattended} ladder below,
      #   which refuses without asking this rung anything.
      #
      #   Defaults to a verdict restricting no program, so a board built
      #   without a project behaves as it did before the table existed --
      #   resolved at CALL time, because `lain.rb` loads `lain/cli` before
      #   `lain/shell`.
      # @param attended [Boolean] whether a human is at this session's terminal
      #   at all. `--non-interactive` says no, which answers "who decides a
      #   gated call" with "nobody can, so refuse" -- see {#seed} for why
      #   refusing beats the two alternatives. Spelled positively all the way
      #   down the chain ({CLI::Wiring#attended?}, {Repl}, {Wiring::Askers}), so
      #   no reader has to un-negate it twice.
      # @param test_layout [Middleware::GuardTestLayout::Run] as on {.for};
      #   a board of its own that declares no layout by default, so the
      #   direct-construction seams a spec drives enforce nothing
      # @param layers [Array<Symbol>] the mode layers the session starts with,
      #   in the starting scope and approval
      # @param spike [#acquire, #reminder, #release] where `/mode plan` leases
      #   the directory the session is confined to: a spike worktree, or a
      #   scratch directory outside git. {Scoping::NOWHERE} by default, which
      #   refuses, so a board built with no project behind it cannot enter plan
      #   scope
      def initialize(journal:, model:, toolset:, rules: [], approving: REMEMBERED,
                     sensitivity: Sensitivity::Policy::Null.instance,
                     classifiers: Approval::Escalation::Triage::AnyPath.new,
                     verdict: Lain::Shell::Verdict.new, test_layout: Middleware::GuardTestLayout::Run.undeclared,
                     attended: true, layers: [], spike: Scoping::NOWHERE)
        @attended = attended
        @journal = journal
        @rules = rules.to_a.freeze
        @approving = approving
        @classifiers = classifiers
        @verdict = verdict
        @spike = spike
        # A parked call has to be answered by somebody, and a queue with no
        # drain is a wait, not a decision.
        @approvals = Approval::Queue.new(journal:) if @attended
        @toolset = toolset
        @model_switch = Context::ModelSwitch.new(model, journal:)
        seed(Mode.new(layers:))
        # After the seed, which is what makes the policy switch it carries.
        @guard_inputs = ToolGuard::Inputs.new(ledger: Sensitivity::Ledger.new, approvals: @approvals, sensitivity:,
                                              test_layout:, policy: @policy_switch, policy_for: method(:policy_for),
                                              denial:, bar: Middleware::WithholdAutomaticOutput::Bar.new,
                                              scope: @scoping)
      end

      # The main agent's context grafted over the live model slot -- the ONLY
      # context that gets it; a subagent renders its role's own.
      def graft(context) = context.with_model(@model_switch)

      # The session a flip into plan scope confines, and a flip out of it
      # releases. Bound rather than built here, for {#bind_snapshots}' reason.
      #
      # @param session [Session]
      # @return [self]
      def bind_session(session)
        @scoping.bind_session(session)
        self
      end

      # The {Agent::SnapshotSlot} the Agent's deliveries write through, or
      # {Agent::SnapshotSlot::Unbound} until the agent build binds one.
      attr_reader :snapshots

      # The snapshot scope every mode writes under, which is what the agent
      # build fills the slot with. The slot falls back to the write-set scope on
      # its own when the shadow store fails, so no mode has to choose it.
      SNAPSHOT_SCOPE = :shadow_git

      def snapshot_scope = SNAPSHOT_SCOPE

      # The slot the Agent's deliveries read, handed to `/undo` through
      # {#surface_kwargs}. Bound rather than built here: it needs the project
      # root, which the board's own build never sees.
      #
      # @param slot [Agent::SnapshotSlot]
      # @return [self]
      def bind_snapshots(slot)
        @snapshots = slot
        @scoping.bind_snapshots(slot)
        self
      end

      # This board's contribution to the {Command::Surface}: the two switches a
      # command WRITES, plus /approve's inline drain prompt over the SAME
      # conductor-routed reader the Repl's watch surface uses (see
      # Repl::ApprovalSurfaces#approval_surface's WHY).
      #
      # {#policy_switch} is deliberately NOT among them. It is DERIVED --
      # {#apply} writes it as the consequence of the mode flip `mode_switch`
      # carries -- so handing it to the command surface would put two writers
      # on one slot, which is what `/mode` exists to avoid.
      #
      # `ledger` rides along because `/survey` projects a corpus through the
      # region model, and a command holding a ledger of its own would show
      # `<redacted:N>` for regions this run has already released. `snapshots`
      # does because `/undo` must read the log the Agent's deliveries feed.
      #
      # `sensitivity` is the same argument about the OTHER half of that command:
      # it walks a tree, and ARCHITECTURE.md's "The secret boundary" says why
      # "the same rules" is not the claim -- the claim is the same OBJECT. It is
      # SNAPSHOTTED here, on the terms {ToolGuard.path_filter} states for its
      # own snapshot, including what has to change should the slot ever become
      # re-bindable.
      def surface_kwargs(conductor:, tty:)
        { model_switch:, mode_switch:, ledger:, sensitivity:, snapshots:,
          approval_prompt: prompt(conductor:, tty:) }
      end

      # The gate policy a worker's calls are asked through. A worker no lease
      # cut a checkout for is judged where the parent is, by the policy switch
      # itself. A leased one is judged by ladders built over the factory its
      # checkout answers -- the triage rung and the rules chain over the SAME
      # one, so the two cannot place a word in different trees -- and at
      # whatever approval level the session is at when it asks. The queue, the
      # journal and the remembered answers are the board's.
      #
      # @param worker_env [WorkerEnv] the environment the worker runs in
      # @return [#rule]
      def policy_for(worker_env)
        classifiers = @classifiers.for(worker_env)
        return @policy_switch if classifiers.equal?(@classifiers)

        Leased.new(ladders: { checkout: ladders(classifiers), plan: plan_ladders(classifiers, worker_env.checkout) },
                   mode_switch: @mode_switch)
      end

      # The gate policy a leased worker is asked through: the ladder for the
      # scope and approval level the session is at NOW, out of the ladders
      # built over that worker's factory. It resolves the mode per call rather
      # than holding a ladder, so a flip reaches a child that was built before it.
      Leased = Data.define(:ladders, :mode_switch) do
        def call(effect, context) = rule(effect, context).allow?

        def rule(effect, context) = current.rule(effect, context)

        # @return [Approval::Escalation] the ladder in force, on
        #   {Approval::PolicySwitch#current}'s terms
        def current
          mode = mode_switch.current
          Mode::Resolution.for(mode:, ladders: ladders.fetch(mode.scope.name)).gate_policy
        end
      end

      private

      # What a refused call is REPORTED as, which is a different question from
      # who refused it and is why it is not the policy's to answer. It rides
      # {#guard_inputs}, so the parent's gate and every child's report a
      # refusal in the same words. A String and nothing else, on {#ladder}'s
      # terms.
      #
      # It covers every refusal but a FINAL one. A triage or rules deny was
      # decided by the session's own rules before anyone could be asked, and
      # {Middleware::Gate::FINAL} reports it with its reason whatever this
      # sentence says.
      #
      # An attended session keeps the default: a human was asked and said no,
      # so trying again later, or differently, is a real move. An UNATTENDED
      # one must not borrow that sentence. `approval denied for tool "bash"` is
      # byte-identical to the human's no, and a model that reads it as one will
      # retry a call nobody can approve, for the whole run. So the unattended
      # denial says what is true -- nobody was asked, nobody can be, this will
      # not change -- and then what to do instead, on
      # {Tools::AskHuman::Unattended}'s rule: a refusal that only says "no"
      # invites the same call again.
      def denial
        return Middleware::Gate::DENIAL if @attended

        "no approval is possible for tool %<name>s: this session was started with --non-interactive, " \
          "so no human is attached and nothing can approve a gated call. This is not somebody answering " \
          "no -- retrying will fail the same way every time. Do what you can without this tool, or stop " \
          "and say what it was for."
      end

      # The starting mode's resolution seeds the policy slot DIRECTLY rather
      # than through {#apply}, because construction journals no policy: every
      # session starts at the same approval level.
      #
      # CONSTRUCTION ORDER: both ladders are built FIRST, ONCE, before the
      # first {#resolve} -- they are what the approval levels resolve TO, and a
      # flip that selects the ladder already in force is then the identical
      # object, which is how the policy switch sees that nothing moved.
      def seed(initial)
        @snapshots = ::Lain::Agent::SnapshotSlot::Unbound
        @ladders = ladders(@classifiers)
        @ladder = @ladders.fetch(:ask)
        @scoping = Scoping.new(spike: @spike, ladders: @ladders,
                               plan_ladders: ->(env) { plan_ladders(@classifiers.for(env), env.checkout) })
        @policy_switch = Approval::PolicySwitch.new(resolve(initial, @ladders).gate_policy, journal: @journal)
        @mode_switch = BoundSwitch.new(launched(initial), scoping: @scoping, resolve: method(:resolve),
                                                          apply: method(:apply))
      end

      # Both approval levels' ladders over one classifier factory, the triage
      # rung and the rules chain each built over it.
      def ladders(classifiers)
        triage = Approval::Escalation::Triage.new(sensitivity: classifiers, verdict: @verdict)
        rules = @approving.call(@rules, classifiers)
        { ask: build_ladder(triage:, rules:), auto: automatic_ladder(triage:, rules:) }.freeze
      end

      # Both approval levels' ladders under plan scope, over the factory of the
      # directory the session is confined to. Triage is the same, and the rules
      # rung is the same but for one thing: a remembered answer is about a
      # command's shape in the checkout and knows nothing of the spike, so it
      # may still refuse a command but never approve one, and the confinement
      # rule is the only approver a command has ({DeniesOnly}). What differs
      # below them is the bottom, where a command nothing confined goes to a
      # human at either level ({Unconfinable}).
      def plan_ladders(classifiers, root)
        triage = Approval::Escalation::Triage.new(sensitivity: classifiers, verdict: @verdict)
        rules = @approving.call(@rules.map { |rule| DeniesOnly.new(rule) }, classifiers)
        asking = @approvals ? Approval::Escalation::Surfaces.new(@approvals) : Unattended.new
        { ask: confined_ladder("plan ask", triage:, rules:, asking:, otherwise: asking, root:),
          auto: confined_ladder("plan auto", triage:, rules:, asking:, root:,
                                             otherwise: Approval::Escalation::Remainder.new) }.freeze
      end

      def confined_ladder(label, triage:, rules:, asking:, otherwise:, root:)
        bottom = Unconfinable.new(asking:, otherwise:, root:)
        Approval::Escalation.new([triage, Approval::Escalation::Rules.new(rules:, tools: @toolset, faults:), bottom],
                                 journal: @journal, label:)
      end

      def faults = Approval::Escalation::Faults.new(@journal)

      # A layer the launch flags turned on IS journaled, as the flip `/mode`
      # would have written to reach it: the session header carries no flags,
      # and the status line and a bench reader fold the mode off the journal
      # alone, so an unrecorded layer would show nowhere but the live prompt
      # until the first `/mode`. A launch with no layer writes nothing, so a
      # plain chat's record is unchanged.
      def launched(initial)
        Mode::Switch.new(initial.with(layers: Mode::LayerSet.empty), journal: @journal).tap do |switch|
          switch.switch(initial, surface: LAUNCH_SURFACE)
        end
      end

      # What `ask` approval resolves to is the LADDER, not the bare queue.
      # The queue is still the parked list `/approve` drains and still the
      # bottom rung; the deterministic rungs simply get asked first, so a call
      # the session has already decided about never reaches a human.
      #
      # It is TOTAL -- both arms answer an {Approval::Escalation}, never nil. A
      # session with nobody to ask gets a ladder of ONE {Unattended} rung, and the two
      # rejected alternatives are why it refuses. Approving would be `auto`
      # approval under another name, granted to a run the operator never said
      # that about. Parking is worse than it looks -- the call waits on a queue
      # no surface drains until the fail-closed timeout denies it anyway, so
      # the outcome is identical and the run spends the wait first.
      #
      # A rung rather than the flat {Middleware::Gate::DenyAll} that stood
      # here before, for two reasons. {Mode::Resolution} refuses a nil `queue:`
      # outright, and a `|| DenyAll` here made that guard unreachable on the
      # only production path -- worse than never having written it, because a
      # reader finds a guard that looks like it covers the case. And DenyAll
      # holds no journal, so an unattended run's refusals were written down
      # nowhere at all; a ladder journals every rung it consults, which is what
      # makes an unattended arm's denials comparable with an attended arm's.
      #
      # It is still NOT a quiet change of mode: the mode stays what it says,
      # the capability set is untouched, and only the gate's answer changes.
      #
      # The unattended arm builds no triage rung at all, which is why the
      # session's verdict and its exclusion table reach nothing here: refusing
      # everything is already stricter than any table could be.
      def build_ladder(triage:, rules:)
        return Approval::Escalation.new([Unattended.new], journal: @journal, label: "ask") unless @approvals

        Approval::Escalation.for(queue: @approvals, tools: @toolset, journal: @journal, rules:, triage:)
      end

      # `auto` approval's ladder, built for attended and unattended sessions
      # alike: nobody is asked under it, so whether anybody could be changes
      # nothing, and the triage and rules rungs still decide first.
      def automatic_ladder(triage:, rules:)
        Approval::Escalation.automatic(tools: @toolset, journal: @journal, rules:, triage:)
      end

      # A mode as this session's live collaborators, out of the ladders the
      # scope it is entering stands on. Pure, and it raises before anything moves.
      def resolve(mode, ladders) = Mode::Resolution.for(mode:, ladders:)

      # What a flip DOES. The gate policy goes through the ONE PolicySwitch
      # every surface writes, so a transcript reads as a single policy history
      # and the last flip wins whichever surface made it.
      def apply(resolution, surface:)
        @policy_switch.switch(resolution.gate_policy, surface:)
      end

      def prompt(conductor:, tty:)
        Frontend::ApprovalPolicy.new(reader: ->(question) { conductor.read_reply(tty, question) })
      end

      # The {Mode::Switch} the command surface writes, decorated so a flip does
      # something. The doing is one ordering, and the order is the contract:
      #
      #   move     -- a flip into plan scope leases its directory; nothing else
      #               touches the disk
      #   resolve  -- pure, and raises here if the mode cannot be bound at all
      #   switch   -- the flip is journaled and the slot moves
      #   commit   -- the session, its snapshots and its scope follow
      #   apply    -- the gate policy follows it
      #
      # Resolving before the record keeps a refused flip out of the journal
      # entirely: the Journal never records a mode the session then failed to
      # enter, and a lease taken for a flip that never landed is released. The
      # converse -- that the harness is never in a mode the Journal missed --
      # holds because the record commits: a live view failing after the record
      # landed is raised only once the gate has followed.
      #
      # A decorator rather than a hook on {Mode::Switch} because the switch is
      # a delegating VALUE -- nothing about "what a session re-binds when its
      # mode changes" is its question.
      class BoundSwitch
        delegate :current, :scope, :approval, :layers, :describe, to: :@switch

        def initialize(switch, scoping:, resolve:, apply:)
          @switch = switch
          @scoping = scoping
          @resolve = resolve
          @apply = apply
        end

        # A live view failing after a record landed does not stop the apply:
        # the mode record committed the flip, so the gate follows it before the
        # failure is raised.
        def switch(mode, surface:)
          move = @scoping.move(mode.scope)
          resolution, recorded = recorded(move, mode, surface)
          failures = [recorded, JournalTee.landed { @apply.call(resolution, surface:) }].compact
          raise failures.first unless failures.empty?

          @switch.current
        end

        # What the last flip's scope move said: the words giving a spike back
        # left, and nothing for every other flip.
        def said = @said || ""

        private

        # `ensure`, so a cancelled flip gives its lease back too.
        def recorded(move, mode, surface)
          resolution = @resolve.call(mode, move.ladders)
          landed = JournalTee.landed { @switch.switch(mode, surface:) }
          @said = move.commit
          [resolution, landed]
        ensure
          move.abandon
        end
      end

      # Where the session's scope stands, and the one place it moves. A flip
      # into plan leases a directory from the spike, and only once the flip is
      # recorded does the session run there: its worker env and reminders
      # ({Session#rescope}) and its snapshots root at the lease. A flip out
      # gives the lease back, and the gc's retention rules decide what stays.
      class Scoping
        # The session of a board no agent build has bound one to, which is
        # refused before a lease is taken for it.
        module Unbound; end

        # The spike of a board built with no project behind it.
        NOWHERE = Class.new do
          def acquire = raise(Error, "plan scope needs a project to cut a spike from, and this board has none")
        end.new.freeze

        UNBOUND = "no session is bound to this board to confine"

        # The checkout scope, and the ladders the board was built with.
        Home = Data.define(:ladders) do
          def plan? = false

          def scope = ::Lain::Session::Unconfined
        end

        # A leased plan scope and the ladders it is judged by.
        Held = Data.define(:lease, :confined, :ladders) do
          def plan? = true

          def scope = confined
        end

        # One flip's movement of the scope, undone unless it was committed.
        # Committing answers what the move has to say.
        class Move
          attr_reader :ladders

          def initialize(ladders:, commit: -> { "" }, abandon: -> {})
            @ladders = ladders
            @commit = commit
            @abandon = abandon
            @committed = false
          end

          def commit
            @committed = true
            @commit.call
          end

          def abandon
            @abandon.call unless @committed
          end
        end

        # @param spike [#acquire, #reminder] as on {Switchboard#initialize}
        # @param ladders [Hash{Symbol => #rule}] the checkout's, by approval level
        # @param plan_ladders [#call] `worker_env -> ladders`, under plan scope
        def initialize(spike:, ladders:, plan_ladders:)
          @spike = spike
          @plan_ladders = plan_ladders
          @home = Home.new(ladders:)
          @state = @home
          @session = Unbound
          @snapshots = ::Lain::Agent::SnapshotSlot::Unbound
        end

        def bind_session(session)
          @session = session
        end

        # @return [Session::Unconfined, Session::Confined] the scope in force
        def current = @state.scope

        # The root the snapshots return to when the scope is lifted.
        def bind_snapshots(slot)
          @snapshots = slot
          @home_root = slot.root
        end

        # @param scope [Mode::Scope] the scope the flip moves to
        # @return [Move]
        # @raise [Mode::Scope::Unavailable] entering plan when no spike can be
        #   set up, or no session is bound to confine
        def move(scope)
          planned = scope.name == :plan
          return Move.new(ladders: @state.ladders) if planned == @state.plan?

          planned ? entering : Move.new(ladders: @home.ladders, commit: -> { leave })
        end

        private

        # Any failure from the lease on is the scope being unavailable, and a
        # lease already taken is given back before it says so.
        def entering
          raise ::Lain::Mode::Scope::Unavailable, unavailable(UNBOUND) if @session.equal?(Unbound)

          lease = @spike.acquire
          held = held(lease)
          Move.new(ladders: held.ladders, commit: -> { enter(held) }, abandon: -> { @spike.release(lease) })
        rescue StandardError => e
          @spike.release(lease) if lease
          raise if e.is_a?(::Lain::Mode::Scope::Unavailable)

          raise ::Lain::Mode::Scope::Unavailable, unavailable(e.message)
        end

        def held(lease)
          env = lease.worker_env
          confined = ::Lain::Session::Confined.new(worker_env: env, reminder: @spike.reminder(lease))
          Held.new(lease:, confined:, ladders: @plan_ladders.call(env))
        end

        def unavailable(why) = "plan scope could not be entered: #{why}"

        def enter(held)
          @state = held
          @session.rescope(held.confined)
          @snapshots.rebind(root: held.confined.root)
          ""
        end

        def leave
          held = @state
          @state = @home
          @session.rescope(::Lain::Session::Unconfined)
          @snapshots.rebind(root: @home_root)
          @spike.release(held.lease)
        end
      end

      # A remembered answer under plan scope: it may still refuse a command, but
      # its allow is withheld, since it names a command's shape in the checkout
      # and says nothing of whether the command stays in the spike. Every other
      # tool's answer stands.
      class DeniesOnly < Approval::Rule
        def initialize(rule)
          @rule = rule
          super()
          freeze
        end

        def name = @rule.name

        def decide(call)
          decision = @rule.decide(call)
          return decision unless decision&.allow? && Unconfinable::COMMANDS.include?(call.tool_name)

          nil
        end
      end

      # The bottom rung under plan scope. A command no rung above approved --
      # none proved its words confined to the scope's directory -- goes to a
      # human whatever the approval level, and nothing automatic may decide it:
      # the directory confines only what is written into it by name, and this
      # command's words may name anything. Every other call reaches the level's
      # own bottom.
      #
      # The wording rides the ruling, so the record says why a command under
      # `auto` waited for a person.
      class Unconfinable
        NAME = "plan_scope"

        COMMANDS = Approval::Escalation::Triage::COMMAND_TOOLS

        UNCONFINED = "plan scope cannot confine this command to %<root>s, so a human decides it whatever the " \
                     "approval level"

        # A context barring automatic approval, so the park is a person's alone.
        class HumansOnly < SimpleDelegator
          def automatic_approval_barred? = true
        end

        def initialize(asking:, otherwise:, root:)
          @asking = asking
          @otherwise = otherwise
          @because = format(UNCONFINED, root:)
          freeze
        end

        def name = NAME

        def call(effect, context)
          return @otherwise.call(effect, context) unless COMMANDS.include?(effect.name)

          ruling = @asking.call(effect, HumansOnly.new(context))
          ruling.with(reason: "#{@because} -- #{ruling.reason}")
        end
      end

      # The whole ladder of a session with nobody to ask: one rung, refusing.
      #
      # A RUNG rather than a policy standing beside the ladder, so `#ladder`
      # answers the same kind of thing on both arms and the refusal lands in
      # the journal like every other rung's ruling ({#build_ladder} has the
      # rest). It names itself rather than borrowing {Escalation::LADDER},
      # because a reader tallying denials by rung must be able to tell "this
      # run had no human" from "the rungs ran out".
      #
      # What the MODEL is told is {Switchboard#denial}'s question, one layer up
      # at the Gate.
      class Unattended
        NAME = "unattended"
        BECAUSE = "no human is attached to this session, so no rung can ask anybody and nothing can approve"

        # Frozen on {Approval::Escalation::Triage}'s terms: a rung holds no
        # state, and a ladder is a value.
        def initialize = freeze

        def name = NAME

        def call(_effect, _context) = Approval::Escalation::Ruling.deny(rung: NAME, because: BECAUSE)
      end
    end
  end
end
