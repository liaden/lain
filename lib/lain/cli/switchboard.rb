# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/module/delegation"

module Lain
  module CLI
    # The live switches a session's commands flip, lifted out of {Wiring}
    # because "which switches exist, what they start as, and what a flip
    # re-binds" is its own responsibility (the Metrics trip said so: extract, do
    # not loosen):
    #
    # * ONE {Approval::PolicySwitch} the Gate holds for the whole session --
    #   a posture flip re-binds the delegate inside it, Gate stays
    #   construction-fixed. An attended session's {Approval::Queue} is the
    #   parked list `/approve` drains, and the {Approval::Escalation} ladder
    #   OVER it is what the asking rungs resolve to -- so the deterministic rungs
    #   answer first and the queue is where a call lands when they abstain. An
    #   unattended one wires NO queue ({#approvals} is nil then, so Wiring's
    #   callers keep their existing no-queue paths).
    # * ONE {Context::ModelSwitch} the main agent's Context reads at render
    #   time -- `/model` writes it, {#graft} installs it.
    # * ONE {Mode::Switch} holding the session's posture and layers -- `/mode`
    #   writes it, the prompt and the HUD read it.
    # * ONE {LiveToolset} the Agent and its executor are BUILT with -- the
    #   capability set a posture attenuates, re-bound in place.
    #
    # == The starting mode is the only thing chosen here
    #
    # Nothing in this class re-states what a posture MEANS. It picks the
    # starting {Mode}, and {Mode::Resolution} answers the gate policy and the
    # capability set that mode implies -- {Mode::Posture}'s table says
    # "approve everything" in one place, for the starting mode and for every
    # flip after it.
    #
    # Every switch journals its flips to the SAME journal approval decisions
    # land in: on a study bench "who flipped what, when" is evidence.
    class Switchboard
      # All four slots live HERE rather than in {Wiring} for a mechanical
      # reason, not a tidiness one: each needs the run's `journal:`, and Wiring's
      # only source for one is `chronicle.record_journal`, which OPENS a file per
      # call (/dev/null under --no-journal) -- the leak wiring.rb:363-366
      # documents and fixed for #goal_driver. This class resolves that journal
      # exactly once and builds all of them over it.
      # `ladder` is read-only in the strongest sense: neither thing it can
      # answer has a writer at all, so exposing it hands out the reading
      # ("which rungs are in force, in what order") and no authority. That is
      # the same line {LiveToolset} draws below, and it is why it can sit beside
      # the switches without being one. For a session with nobody to ask it is an
      # {Approval::Escalation} too -- one {Unattended} rung, refusing -- and the
      # reading is then "no rung asks anybody, everything refuses", still a
      # reading and still no authority. Never nil, and never a different KIND of
      # thing, so no caller writes `if board.ladder` and nothing has to ask
      # which arm built it.
      # `sensitivity` sits beside `ladder` for the same reason and on the same
      # terms: it is a frozen {Sensitivity::Policy} with no writer, so exposing
      # it hands out the reading ("which paths this session gates") and no
      # authority. It is read here by the parent's gate and, through the board
      # thunk, by every child's -- ONE policy, so the two cannot disagree.
      # `ledger` is the opposite kind of slot and sits beside `approvals`, not
      # beside those two: it is deliberately mutable run state, and the reading
      # IS the authority to release. It is exposed for one reason -- the masking
      # arm and the approval arm must hold the SAME one, and two half-wirings
      # would give the run two ledgers and a release control that silently
      # releases nothing. Constructed for a queueless session too: the posture
      # decides who is asked, not whether the run has somewhere to record an
      # answer.
      attr_reader :approvals, :ladder, :ledger, :policy_switch, :model_switch, :mode_switch, :toolset, :sensitivity

      # The wiring entry: resolves the journal the chronicle carries -- the
      # null device under --no-journal (the operator declined the record, not
      # the gate) -- then builds the switches over it, reading the one surface
      # flag that changes them (`--non-interactive`) off the CLI options itself.
      # `--auto-approve` is NOT read here: it wires an adjudicating surface, and
      # that is {CLI::Wiring::ToolsetBuild}'s to build.
      #
      # `toolset:` is the run's BASE capability set, and base is the whole point:
      # attenuation is monotone, so every posture resolves from the set the
      # session was built with and never from what the previous posture left
      # behind (see {Mode::Resolution}'s note on `base:`).
      #
      # `rules:` and `sensitivity:` are two vocabularies and never one. `rules:`
      # is APPROVAL -- remembered answers about call SHAPES, which grant. The
      # other is the PATH classifier, which restricts and grants nothing. They
      # travel side by side here because the run has exactly one of each, and
      # neither may be passed where the other is expected.
      #
      # @param chronicle [#record_journal] the run's chronicle; its journal is
      #   what the switches record onto
      # @param options [Hash] the CLI's parsed surface flags
      # @param model [String] the model in force until the first /model
      # @param toolset [Lain::Toolset] the run's BASE capability set
      # @param rules [Enumerable<Approval::Rule>] the deterministic rung's rules,
      #   which for a live session is {Project::Consent#rules} -- the remembered
      #   answers a CONSENTED root is allowed to contribute
      # @param sensitivity [#gates?] which PATHS this session gates, built by
      #   {CLI::Wiring} over the resolved {Project} and that project's
      #   `[sensitivity]` table. Defaulted to the same Null `new` defaults to,
      #   so the direct-construction seams a spec drives are unchanged
      # @param classifiers [#call] the triage rung's `cwd -> #classify` factory,
      #   on `new`'s terms
      # @option options [Boolean] :non_interactive no human is at this
      #   session's terminal -- the only flag this entry reads off `options`, so
      #   a board built here differs from `new` in exactly that one resolution
      # @return [Switchboard]
      def self.for(chronicle:, options:, model:, toolset:, rules: [],
                   sensitivity: Sensitivity::Policy::Null.instance,
                   classifiers: Approval::Escalation::Triage::AnyPath.new)
        new(journal: chronicle.record_journal, model:, toolset:, rules:, sensitivity:, classifiers:,
            attended: !options[:non_interactive])
      end

      # @param journal [#record] where flips and approval decisions land
      # @param model [String] the model in force until the first /model
      # @param toolset [Lain::Toolset] the run's full capability set. Required,
      #   with no empty-set default, for the reason build_agent's `session:` is:
      #   a board built without one resolves every posture against nothing, so
      #   the model would be shown no tools at all and `/mode plan` would raise
      #   {Toolset::UnknownTool} on a name the run really does hold. A forgotten
      #   collaborator must be an ArgumentError here, not a mystery one turn on.
      # @param rules [Enumerable<Approval::Rule>] consulted by the ladder's
      #   deterministic `rules` rung, ahead of the queue and ahead of any human.
      #   EMPTY by default, which abstains on everything and so changes no
      #   outcome: filling it is {Project::Consent}'s decision, never this
      #   board's, because only a CONSENTED root's answers may grant authority.
      # @param sensitivity [#gates?] which PATHS this session gates, whatever
      #   the tool's own tier. {Sensitivity::Policy::Null} by default, so a
      #   session that resolved no project root behaves byte-for-byte as it did
      #   before this axis existed.
      # @param classifiers [#call] `cwd -> #classify`, the factory the ladder's
      #   triage rung anchors a bash argv on. THE THIRD VOCABULARY on this
      #   board, and its resemblance to `sensitivity:` is a trap worth naming:
      #   that one is the run's path BOUNDARY, asked `gates?` about a path a
      #   tool already resolved; this one is asked for a FRESH classifier per
      #   gated command, because a command names its own working directory.
      #   {Approval::Escalation::Triage::AnyPath} by default, which protects
      #   nothing -- a board built with no project knows no home to anchor on.
      #   {CLI::Wiring::BoardBuild::Classifiers} is what a real chat passes, and
      #   board_build_spec asserts that IDENTITY rather than the behaviour:
      #   dropping the argument at the one call site restores this default and
      #   disarms the rung with a fully green suite, which is exactly how the
      #   argv check came to be dead for two chunks.
      # @param attended [Boolean] whether a human is at this session's terminal
      #   at all. `--non-interactive` says no, which answers "who decides a
      #   gated call" with "nobody can, so refuse" -- see {#seed} for why
      #   refusing beats the two alternatives. Spelled positively all the
      #   way down the chain ({CLI::Wiring#attended?}, {Repl},
      #   {Wiring::Askers}), so no reader has to un-negate it twice to find out
      #   what it means.
      def initialize(journal:, model:, toolset:, rules: [],
                     sensitivity: Sensitivity::Policy::Null.instance,
                     classifiers: Approval::Escalation::Triage::AnyPath.new, attended: true)
        @attended = attended
        @sensitivity = sensitivity
        @classifiers = classifiers
        @rules = rules.to_a.freeze
        @ledger = Sensitivity::Ledger.new
        # Kept, where the switches merely borrow it: {#gate}'s path refusals are
        # journaled at the moment they happen, and re-resolving one per gate
        # would leak an fd -- {Chronicle::Null#record_journal} opens the null
        # device on EVERY call, which is the leak this class was extracted to
        # stop happening once.
        @journal = journal
        # A parked call has to be answered by somebody. An unattended run has
        # nobody to answer one, and a queue with no drain is a wait, not a
        # decision.
        @approvals = Approval::Queue.new(journal:) if @attended
        @base = toolset
        @model_switch = Context::ModelSwitch.new(model, journal:)
        seed(Mode.new(posture: :accept_edits), journal:)
      end

      # The main agent's context grafted over the live model slot -- the ONLY
      # context that gets it; a subagent renders its role's own.
      def graft(context) = context.with_model(@model_switch)

      # The session's approval gate over `inner`: the Gate holds this board's
      # ONE policy switch, so every posture flip reaches it while the Gate
      # itself stays construction-fixed.
      #
      # {Effect::Handler::Sensitivity} sits AHEAD of it, over the SAME one
      # policy: a denied path is not approvable, and a Gate policy answer is a
      # Boolean, so every Boolean is approvable by construction. Two axes, two
      # handlers, in the order that leaves the human a move on the axis that has
      # one -- the gated path reaches the queue, the denied one never does.
      #
      # Nothing here reads the session's posture, and that is the point: the
      # refusal is decided before the policy switch is consulted, so a session
      # approving everything refuses a denied path exactly as an asking one
      # does.
      def gate(inner:)
        Effect::Handler::Sensitivity.new(
          sensitivity:, journal: @journal,
          inner: Effect::Handler::Gate.new(policy: policy_switch, inner:, sensitivity:, denial:)
        )
      end

      # What a refused call is REPORTED as, which is a different question from
      # who refused it and is why it is not the policy's to answer.
      #
      # PUBLIC, and read from two places for one reason: {#gate} builds the
      # parent's own gate, and {CLI::Wiring::ToolsetBuild::spawn_seam} threads
      # this same value onto every child's seam. A String and nothing else --
      # the reading, never any authority -- on {#ladder}'s terms.
      #
      # An attended session keeps the default, and the default is right there:
      # a human was asked and said no, so trying again later, or differently,
      # is a real move. An UNATTENDED one must not borrow that sentence.
      # `approval denied for tool "bash"` is byte-identical to the human's no,
      # and a model that reads it as one will retry a call that cannot be
      # approved by anybody, for the whole run. So the unattended denial says
      # what is actually true -- nobody was asked, nobody can be, and this will
      # not change -- and then says what to do instead, on {Tools::AskHuman::Unattended}'s
      # rule: a refusal that only says "no" invites the same call again.
      def denial
        return Effect::Handler::Gate::DENIAL if @attended

        "no approval is possible for tool %<name>s: this session was started with --non-interactive, " \
          "so no human is attached and nothing can approve a gated call. This is not somebody answering " \
          "no -- retrying will fail the same way every time. Do what you can without this tool, or stop " \
          "and say what it was for."
      end

      # This board's contribution to the {Command::Surface}: the two switches a
      # command WRITES, plus /approve's inline drain prompt over the SAME
      # conductor-routed reader the Repl's watch surface uses (see
      # Repl::ApprovalSurfaces#approval_surface's WHY).
      #
      # {#policy_switch} is deliberately NOT among them. It is DERIVED -- {#apply}
      # writes it as the consequence of the mode flip `mode_switch` carries -- so
      # handing it to the command surface would put two writers on one slot,
      # which is what `/mode` exists to avoid. It stays this board's, read by
      # {#gate} and by every child's seam through the board thunk.
      #
      # `ledger` rides along for the reason the reader above exists: `/survey`
      # projects a corpus through the region model, and a command holding a
      # ledger of its own would show `<redacted:N>` for regions this run has
      # already released. One ledger, or the release control silently releases
      # nothing.
      def surface_kwargs(conductor:, tty:)
        { model_switch:, mode_switch:, ledger:, approval_prompt: prompt(conductor:, tty:) }
      end

      private

      # The starting mode's resolution seeds both live slots DIRECTLY rather
      # than through {#apply}, because construction must journal nothing: the
      # initial policy is the wiring's choice and is already visible in the
      # session's flags, which is the rule {Approval::PolicySwitch} and
      # {Mode::Switch} each state for themselves.
      # The live toolset slot and the ladder are built FIRST, before the first
      # {#resolve}: the ladder is what the asking rungs resolve TO, and its
      # deterministic rung reads the tier off the live capability set. The slot
      # answers through a thunk, so it may be built while `@resolved` is still
      # nil -- nothing asks it anything until a call is gated.
      def seed(initial, journal:)
        @toolset = LiveToolset.new(-> { @resolved })
        @ladder = build_ladder(journal:)
        resolution = resolve(initial)
        @resolved = resolution.toolset
        @policy_switch = Approval::PolicySwitch.new(resolution.gate_policy, journal:)
        @mode_switch = BoundSwitch.new(Mode::Switch.new(initial, journal:),
                                       resolve: method(:resolve), apply: method(:apply))
      end

      # What an asking posture actually resolves to is the LADDER, not the
      # bare queue. The queue is still the parked list `/approve` drains and is
      # still the bottom rung -- the deterministic rungs simply get asked first,
      # so a call the session has already decided about never reaches a human,
      # and every rung's answer lands in the same journal the flips do.
      #
      # TOTAL: both arms answer an {Approval::Escalation}, and neither answers
      # nil. A session with nobody to ask gets a ladder of ONE {Unattended}
      # rung, and the two rejected alternatives are why it refuses. Approving
      # would be the `auto` posture under another name, granted to a run the
      # operator never said that about: the one answer this may not silently be.
      # Parking is worse than it looks -- the call waits on a queue no surface
      # drains until the fail-closed timeout denies it anyway, so the outcome is
      # identical and the run spends the wait first.
      #
      # A rung rather than the flat {Effect::Handler::Gate::DenyAll} that stood
      # here before, for two reasons. The first is the guard one file over:
      # {Mode::Resolution} refuses a nil `queue:` outright, and a `|| DenyAll`
      # here made that guard unreachable on the only production path -- worse
      # than never having written it, because a reader finds a guard that looks
      # like it covers the case. The second is the RECORD. {Effect::Handler::Gate::DenyAll}
      # holds no journal, so an unattended run's refusals were written down
      # nowhere at all; a ladder journals every rung it consults, which is what
      # makes an unattended arm's denials comparable with an attended arm's on
      # the bench.
      #
      # It is still NOT a quiet demotion to `plan`: the posture stays what it
      # says, the capability set is untouched, and only the gate's answer
      # changes. `--non-interactive` is a declared arm, so its record is honest
      # by construction, where an accidentally queueless `manual` would not be.
      def build_ladder(journal:)
        return Approval::Escalation.new([Unattended.new], journal:) unless @approvals

        Approval::Escalation.for(queue: @approvals, tools: @toolset, journal:, rules: @rules,
                                 triage: Approval::Escalation::Triage.new(sensitivity: @classifiers))
      end

      # The posture's declared symbols as this session's live collaborators.
      # Pure, and it raises before anything moves -- {Toolset::UnknownTool} when
      # a posture names a tool this run does not hold.
      def resolve(mode) = Mode::Resolution.for(mode:, base: @base, queue: @ladder)

      # What a flip DOES. The gate policy goes through the ONE PolicySwitch
      # every surface writes, so a transcript reads as a single policy history
      # and the last flip wins regardless of which surface made it; the
      # capability set is re-bound in the slot the Agent and the executor
      # already hold.
      #
      # `snapshot_scope` is deliberately NOT bound here: {Workspace::Snapshot}
      # primes its scope against a root at construction, and the Agent's
      # `snapshot_writer:` has no live slot yet. That rung of the ladder is owed.
      def apply(resolution, surface:)
        @policy_switch.switch(resolution.gate_policy, surface:)
        @resolved = resolution.toolset
      end

      def prompt(conductor:, tty:)
        Frontend::ApprovalPolicy.new(reader: ->(question) { conductor.read_reply(tty, question) })
      end

      # The capability set the Agent and {Effect::Handler::Live} are BUILT with,
      # so a posture flip can change what the model is shown without rebuilding
      # either. Exactly {Approval::PolicySwitch}'s shape one axis over, and for
      # the same seam reality: both holders are construction-fixed, so the live
      # thing has to be a slot they already have.
      #
      # == It is a read-only FACE, and the writer stays on the board
      #
      # This object is frozen and has no writer at all: it reads `@resolved`
      # through a thunk, and only {Switchboard#apply} moves that. The obvious
      # shape -- a public `#bind` mirroring {Approval::PolicySwitch#switch} --
      # was built first and rejected at review, because it is not the same kind
      # of write. Its three siblings journal every flip with the surface that
      # made it; a `#bind` on this reader would be the one authorization write
      # in the family that is unattributable, sitting in public on `agent.toolset`
      # where `bind(Toolset.new)` disarms a live session to zero tools, writes no
      # journal line, and leaves the mode slot still reading `accept_edits`. In a
      # codebase whose premise is "possession is authorization", the object that
      # IS the possession must not offer a silent disarm.
      #
      # It delegates the model-facing surface and NOTHING else -- the rendered
      # schema, the `include?`/`fetch` pair Live authorizes and dispatches with,
      # and the Enumerable seam {Agent::ToolRunner} harvests answered questions
      # through. Not a `SimpleDelegator`: `only`/`except` deliberately do not
      # pass through, because attenuating the live slot would answer a plain
      # Toolset and read like a second, competing expression of the ladder.
      #
      # `==` and `hash` are deliberately absent, so `live == live.current` is
      # false in both directions even though {Toolset#==} exists: this is a slot,
      # not a value, and two slots holding equal sets are still two sessions.
      # Compare `live.current`, or `live.digest`, and never the face.
      class LiveToolset
        include Enumerable
        include Inspectable

        delegate :to_schema, :include?, :fetch, :[], :each, :names, :digest, :size, :empty?, :to_s, to: :current

        # @param source [#call] answers the {Toolset} in force right now
        def initialize(source)
          @source = source
          freeze
        end

        # Read every time rather than memoized: being late is the entire job.
        def current = @source.call
      end

      # The {Mode::Switch} the command surface writes, decorated so a flip does
      # something. An earlier card established WHERE the live mode lives and left the doing
      # to this card; the doing is one ordering, and the order is the contract:
      #
      #   resolve  -- pure, and raises here if the mode cannot be bound at all
      #   switch   -- the slot moves and the flip is journaled
      #   apply    -- the gate policy and the capability set follow it
      #
      # Resolving FIRST is what keeps a refused flip out of the journal
      # entirely: the Journal never records a mode the session then failed to
      # enter. Only that half is enforced. The converse -- that the harness is
      # never in a mode the Journal missed -- rests on `apply` not raising, and
      # nothing here would catch it if it did: the record would be written and
      # the gate would still be on the old policy. Unreachable today (`apply`
      # only calls a switch and an assignment, and everything that CAN fail
      # failed in `resolve`), and stated rather than claimed away, because the
      # day `apply` grows a fallible step is the day the order needs revisiting.
      #
      # A decorator rather than a hook on {Mode::Switch} because the switch is a
      # delegating VALUE -- it holds a Mode and a journal, and nothing about
      # "what a session re-binds when its posture changes" is its question.
      class BoundSwitch
        delegate :current, :posture, :layers, :describe, to: :@switch

        def initialize(switch, resolve:, apply:)
          @switch = switch
          @resolve = resolve
          @apply = apply
        end

        def switch(mode, surface:)
          resolution = @resolve.call(mode)
          @switch.switch(mode, surface:)
          @apply.call(resolution, surface:)
          @switch.current
        end
      end

      # The whole ladder of a session with nobody to ask: one rung, refusing.
      #
      # A RUNG rather than a policy standing beside the ladder, so `#ladder`
      # answers the same kind of thing on both arms and the refusal lands in the
      # journal like every other rung's ruling -- see {#build_ladder} for both
      # halves of that reasoning. It names itself rather than borrowing
      # {Escalation::LADDER}, because a reader tallying denials by rung must be
      # able to tell "this run had no human" from "the rungs ran out".
      #
      # What the MODEL is told is a different question and is not this rung's:
      # {Switchboard#denial} answers it, one layer up at the Gate.
      class Unattended
        NAME = "unattended"
        BECAUSE = "no human is attached to this session, so no rung can ask anybody and nothing can approve"

        # Frozen on {Approval::Escalation::Triage}'s terms, and {Escalation}'s,
        # and {LiveToolset}'s: a rung holds no state, and a ladder is a value.
        def initialize = freeze

        def name = NAME

        def call(_effect, _context) = Approval::Escalation::Ruling.deny(rung: NAME, because: BECAUSE)
      end
    end
  end
end
