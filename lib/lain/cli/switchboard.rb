# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/module/delegation"

module Lain
  module CLI
    # The live switches a session's commands flip (T14), lifted out of {Wiring}
    # because "which switches exist, what they start as, and what a flip
    # re-binds" is its own responsibility (the Metrics trip said so: extract, do
    # not loosen):
    #
    # * ONE {Approval::PolicySwitch} the Gate holds for the whole session --
    #   `/yolo` flips the delegate inside it, Gate stays construction-fixed.
    #   `--yolo` wires NO queue ({#approvals} is nil then, so Wiring's callers
    #   keep their existing no-queue paths); otherwise the {Approval::Queue} is
    #   the parked list `/approve` drains, and the {Approval::Escalation} ladder
    #   OVER it is what the asking rungs resolve to -- so the deterministic rungs
    #   answer first and the queue is where a call lands when they abstain.
    # * ONE {Context::ModelSwitch} the main agent's Context reads at render
    #   time -- `/model` writes it, {#graft} installs it.
    # * ONE {Mode::Switch} holding the session's posture and layers -- `/mode`
    #   writes it, the prompt and the HUD read it. `--yolo` starts it on `auto`.
    # * ONE {LiveToolset} the Agent and its executor are BUILT with -- the
    #   capability set a posture attenuates, re-bound in place (T10).
    #
    # == The flag is read once, and the ladder says the rest
    #
    # `--yolo` used to be read twice, once per axis, with a comment promising the
    # two could never disagree. They no longer can, because it is read once: it
    # picks the starting {Mode}, and {Mode::Resolution} answers the gate policy
    # and the capability set that mode implies. Nothing here re-states "yolo
    # means approve everything" -- {Mode::Posture}'s table does, in one place,
    # for the starting mode and for every flip after it.
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
      # `ladder` is read-only in the strongest sense: {Approval::Escalation} is a
      # frozen value with no writer at all, so exposing it hands out the reading
      # ("which rungs are in force, in what order") and no authority. That is the
      # same line {LiveToolset} draws below, and it is why it can sit beside the
      # switches without being one.
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
      # releases nothing. Constructed under --yolo too: the posture decides who
      # is asked, not whether the run has somewhere to record an answer.
      attr_reader :approvals, :ladder, :ledger, :policy_switch, :model_switch, :mode_switch, :toolset, :sensitivity

      # The wiring entry: resolves the journal the chronicle carries -- the
      # null device under --no-journal (the operator declined the record, not
      # the gate) -- then builds the switches over it, reading the surface
      # flags (`--yolo`, `--auto-approve`) off the CLI options itself.
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
      # @option options [Boolean] :yolo start approving everything, with no
      #   queue -- the only flag this entry reads off `options`, so a board
      #   built here differs from `new` in exactly that one resolution
      # @return [Switchboard]
      def self.for(chronicle:, options:, model:, toolset:, rules: [],
                   sensitivity: Sensitivity::Policy::Null.instance)
        new(journal: chronicle.record_journal, model:, yolo: options[:yolo], toolset:, rules:, sensitivity:)
      end

      # @param journal [#record] where flips and approval decisions land
      # @param yolo [Boolean] start approving everything, with no queue
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
      def initialize(journal:, yolo:, model:, toolset:, rules: [],
                     sensitivity: Sensitivity::Policy::Null.instance)
        @sensitivity = sensitivity
        @rules = rules.to_a.freeze
        @ledger = Sensitivity::Ledger.new
        # Kept, where the switches merely borrow it: {#gate}'s path refusals are
        # journaled at the moment they happen, and re-resolving one per gate
        # would leak an fd -- {Chronicle::Null#record_journal} opens the null
        # device on EVERY call, which is the leak this class was extracted to
        # stop happening once.
        @journal = journal
        @approvals = yolo ? nil : Approval::Queue.new(journal:)
        @base = toolset
        @model_switch = Context::ModelSwitch.new(model, journal:)
        seed(Mode.new(posture: yolo ? :auto : :accept_edits), journal:)
      end

      # The main agent's context grafted over the live model slot -- the ONLY
      # context that gets it; a subagent renders its role's own.
      def graft(context) = context.with_model(@model_switch)

      # The session's approval gate over `inner`: the Gate holds this board's
      # ONE policy switch, so /yolo flips and posture flips both reach it while
      # the Gate itself stays construction-fixed.
      #
      # {Effect::Handler::Sensitivity} sits AHEAD of it, over the SAME one
      # policy: a denied path is not approvable, and a Gate policy answer is a
      # Boolean, so every Boolean is approvable by construction. Two axes, two
      # handlers, in the order that leaves the human a move on the axis that has
      # one -- the gated path reaches the queue, the denied one never does.
      #
      # Nothing here reads `--yolo`, and that is the point: the refusal is
      # decided before the policy switch is consulted, so a `--yolo` session
      # (which wires no queue at all) refuses a denied path exactly as an
      # attended one does.
      def gate(inner:)
        Effect::Handler::Sensitivity.new(
          sensitivity:, journal: @journal,
          inner: Effect::Handler::Gate.new(policy: policy_switch, inner:, sensitivity:)
        )
      end

      # This board's contribution to the {Command::Surface}: the three switches,
      # plus /approve's inline drain prompt over the SAME conductor-routed
      # reader the Repl's watch surface uses (see Repl::ApprovalSurfaces#approval_surface's WHY).
      def surface_kwargs(conductor:, tty:)
        { policy_switch:, model_switch:, mode_switch:, approval_prompt: prompt(conductor:, tty:) }
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

      # T21: what an asking posture actually resolves to is the LADDER, not the
      # bare queue. The queue is still the parked list `/approve` drains and is
      # still the bottom rung -- the deterministic rungs simply get asked first,
      # so a call the session has already decided about never reaches a human,
      # and every rung's answer lands in the same journal the flips do.
      #
      # `nil` under --yolo, because that session wired no queue: the sentinel in
      # {#resolve} then fires and {#refuse_queueless} explains why, exactly as it
      # did when the queue itself was what a posture asked through.
      def build_ladder(journal:)
        return nil unless @approvals

        Approval::Escalation.for(queue: @approvals, tools: @toolset, journal:, rules: @rules)
      end

      # The posture's declared symbols as this session's live collaborators.
      # Pure, and it raises before anything moves -- {Toolset::UnknownTool} when
      # a posture names a tool this run does not hold, and the refusal below.
      #
      # The sentinel is how the refusal OBSERVES the answer instead of re-asking
      # the question. Testing `posture.gate_policy == :queue` here would be a
      # second reader of {Mode::Posture}'s table, and a future rung whose symbol
      # differs but which still resolves to the queue slot would walk straight
      # past it and be handed the fallback -- the same degrade, through a new
      # door. Passing a value that IS NOT a policy and asking whether the
      # resolution handed it back reads no table at all: whatever the ladder
      # grows, "this rung wanted the queue" is exactly "the queue arm fired".
      def resolve(mode)
        resolution = Mode::Resolution.for(mode:, base: @base, queue: @ladder || NO_QUEUE)
        refuse_queueless(mode.posture) if resolution.gate_policy.equal?(NO_QUEUE)
        resolution
      end

      # `/yolo off`'s doctrine one rung up, and for a sharper reason than that
      # one: a --yolo session wired no queue AND no `/approve` drain to answer
      # it, so building one on demand would not restore `manual` -- it would
      # park every gated call until the fail-closed timeout denied it, a THIRD
      # arm the operator never asked for. Handing the fallback policy over
      # instead is the other degrade, a run journalled as `manual` that approves
      # everything, which is precisely what {Mode::Resolution} refuses a nil
      # `queue:` to prevent. So the flip refuses, and names the way out: the
      # choice was made at the command line and only the command line can unmake
      # it.
      def refuse_queueless(posture)
        raise Error, "no approval queue in this session (started with --yolo); the #{posture.name} posture parks " \
                     "gated calls on one, so there is nothing for it to ask through -- restart without --yolo " \
                     "to use it"
      end

      # What a flip DOES. The gate policy goes through the ONE PolicySwitch
      # /yolo also writes, so a transcript reads as a single policy history and
      # the last flip wins regardless of which surface made it; the capability
      # set is re-bound in the slot the Agent and the executor already hold.
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

      # Stands where the queue would be for a session that has none, so the
      # resolution can be ASKED whether the posture wanted one. Frozen and
      # private: it must never reach a gate, and it cannot -- #resolve raises
      # the moment it comes back.
      NO_QUEUE = Object.new.freeze
      private_constant :NO_QUEUE

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
      # something. T5 established WHERE the live mode lives and left the doing
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
    end
  end
end
