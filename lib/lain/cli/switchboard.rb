# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/module/delegation"

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
      # @param classifiers [#call] the triage rung's `cwd -> #classify` factory,
      #   on `new`'s terms
      # @param verdict [#call] the triage rung's shell verdict, on `new`'s terms
      # @param test_layout [Middleware::GuardTestLayout::Run] the session's
      #   one test layout run. REQUIRED here: a chat with no layout decision
      #   behind it is a mis-wire, not a default
      # @option options [Boolean] :non_interactive no human is at this
      #   session's terminal
      # @option options [Boolean] :auto_approve the session starts with the
      #   `auto_approve` layer on. These two are the only flags this entry
      #   reads off `options`
      # @return [Switchboard]
      def self.for(chronicle:, options:, model:, toolset:, test_layout:, rules: [],
                   sensitivity: Sensitivity::Policy::Null.instance,
                   classifiers: Approval::Escalation::Triage::AnyPath.new,
                   verdict: Lain::Shell::Verdict.new)
        new(journal: chronicle.record_journal, model:, toolset:, rules:, sensitivity:, classifiers:, verdict:,
            test_layout:, attended: !options[:non_interactive], layers: options[:auto_approve] ? [:auto_approve] : [])
      end

      # What the tool stack is built over, as ONE value: the ledger and the
      # path policy described above, the approval queue, the session's one
      # test layout run, the gate's one policy switch, and what a refused call
      # is reported as ({#denial}). The parent's stack and every child's read
      # it, so they hold one of each and say an absence once.
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
      def initialize(journal:, model:, toolset:, rules: [],
                     sensitivity: Sensitivity::Policy::Null.instance,
                     classifiers: Approval::Escalation::Triage::AnyPath.new,
                     verdict: Lain::Shell::Verdict.new, test_layout: Middleware::GuardTestLayout::Run.undeclared,
                     attended: true, layers: [])
        @attended = attended
        # The rung itself, not the two things it is built from: a board that
        # held them apart would be holding a constructor's argument list, and
        # both are read at exactly one place. It is frozen and holds no state,
        # so building it before the ladder that may not want it costs nothing.
        @triage = Approval::Escalation::Triage.new(sensitivity: classifiers, verdict:)
        @rules = rules.to_a.freeze
        # A parked call has to be answered by somebody, and a queue with no
        # drain is a wait, not a decision.
        @approvals = Approval::Queue.new(journal:) if @attended
        @toolset = toolset
        @model_switch = Context::ModelSwitch.new(model, journal:)
        seed(Mode.new(layers:), journal:)
        # After the seed, which is what makes the policy switch it carries.
        @guard_inputs = ToolGuard::Inputs.new(ledger: Sensitivity::Ledger.new, approvals: @approvals, sensitivity:,
                                              test_layout:, policy: @policy_switch, denial:)
      end

      # The main agent's context grafted over the live model slot -- the ONLY
      # context that gets it; a subagent renders its role's own.
      def graft(context) = context.with_model(@model_switch)

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
      def seed(initial, journal:)
        @snapshots = ::Lain::Agent::SnapshotSlot::Unbound
        @ladder = build_ladder(journal:)
        @ladders = { ask: @ladder, auto: automatic_ladder(journal:) }.freeze
        @policy_switch = Approval::PolicySwitch.new(resolve(initial).gate_policy, journal:)
        @mode_switch = BoundSwitch.new(launched(initial, journal:), resolve: method(:resolve), apply: method(:apply))
      end

      # A layer the launch flags turned on IS journaled, as the flip `/mode`
      # would have written to reach it: the session header carries no flags,
      # and the status line and a bench reader fold the mode off the journal
      # alone, so an unrecorded layer would show nowhere but the live prompt
      # until the first `/mode`. A launch with no layer writes nothing, so a
      # plain chat's record is unchanged.
      def launched(initial, journal:)
        Mode::Switch.new(initial.with(layers: Mode::LayerSet.empty), journal:).tap do |switch|
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
      def build_ladder(journal:)
        return Approval::Escalation.new([Unattended.new], journal:, label: "ask") unless @approvals

        Approval::Escalation.for(queue: @approvals, tools: @toolset, journal:, rules: @rules, triage: @triage)
      end

      # `auto` approval's ladder, built for attended and unattended sessions
      # alike: nobody is asked under it, so whether anybody could be changes
      # nothing, and the triage and rules rungs still decide first.
      def automatic_ladder(journal:)
        Approval::Escalation.automatic(tools: @toolset, journal:, rules: @rules, triage: @triage)
      end

      # A mode as this session's live collaborators. Pure, and it raises before
      # anything moves.
      def resolve(mode) = Mode::Resolution.for(mode:, ladders: @ladders)

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
      #   resolve  -- pure, and raises here if the mode cannot be bound at all
      #   switch   -- the flip is journaled and the slot moves
      #   apply    -- the gate policy follows it
      #
      # Resolving FIRST keeps a refused flip out of the journal entirely: the
      # Journal never records a mode the session then failed to enter. The
      # converse -- that the harness is never in a mode the Journal missed --
      # holds because the record commits: a live view failing after the record
      # landed is raised only once the gate has followed.
      #
      # A decorator rather than a hook on {Mode::Switch} because the switch is
      # a delegating VALUE -- nothing about "what a session re-binds when its
      # mode changes" is its question.
      class BoundSwitch
        delegate :current, :scope, :approval, :layers, :describe, to: :@switch

        def initialize(switch, resolve:, apply:)
          @switch = switch
          @resolve = resolve
          @apply = apply
        end

        #
        # A live view failing after a record landed does not stop the apply:
        # the mode record committed the flip, so the gate follows it before the
        # failure is raised.
        def switch(mode, surface:)
          resolution = @resolve.call(mode)
          failures = [JournalTee.landed { @switch.switch(mode, surface:) },
                      JournalTee.landed { @apply.call(resolution, surface:) }].compact
          raise failures.first unless failures.empty?

          @switch.current
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
