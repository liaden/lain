# frozen_string_literal: true

module Lain
  module Approval
    class Gate
      # HOW a verdict is reached, wrapped around the one {Gate} that reaches it.
      #
      # A policy is a SURFACE plus a LABEL, and {#decide} is the whole seam:
      # hand both to {Gate#call} and let it ask, journal, and register. Nothing
      # here builds a {GateDecision} or touches the approval registry, and that
      # is the design, not an economy -- Gate journals BEFORE it registers so a
      # failed journal write can never leave a standing approval behind, and a
      # policy that re-implemented the record would be a second copy of that
      # ordering waiting to disagree with the first. Wrapping preserves it by
      # construction; a spec pins the guarantee through each wrapping anyway.
      #
      # The consequence worth knowing: every policy inherits Gate's reactor
      # precondition (`Sync`/`Async`), including {HandsOff}, whose answer needs
      # no human. That uniformity is deliberate -- one seam, one precondition,
      # no policy-shaped exception to remember.
      #
      # `answered_by` and `policy` stay independent on the record: {Interactive}
      # journals whichever surface actually spoke, while {HandsOff} and
      # {Deferred} ARE their own surface -- nobody answered, and naming that
      # (rather than writing nil) is the same choice {Gate::TIMEOUT_SURFACE}
      # makes for the clock.
      #
      # {Adjudicated} is the one member that does not fit the paragraph above,
      # and deliberately: it reaches its verdict through {Gate::Adjudicator},
      # which already owns the boundary check, the gate call and the park. It
      # therefore overrides {#decide} outright and answers no {#surface} -- see
      # its own comment for why wrapping instead would check the boundary twice.
      class Policy
        # The Null Object a caller NAMES when there is no sign-off queue in the
        # session at all: nothing can be parked, so no boundary can be blocked,
        # and answering `true` is a fact rather than a guess.
        #
        # It has to be named rather than defaulted. A policy quietly built
        # without a queue would open every boundary it was supposed to guard,
        # which is the check's own failure mode -- the same reasoning that makes
        # {Gate}'s `journal:` required rather than defaulted. Naming this is a
        # statement; forgetting it is an ArgumentError.
        module Drained
          def self.drained?(_epic_slug, _stage) = true
        end

        # {Epic::Stage}'s boundary rule, bound to the queue it is asked about --
        # the ONE object that invokes it.
        #
        # It exists because the rule was written twice: here on the policy seam,
        # and again inside {Gate::Adjudicator}, which is not a Policy and never
        # reaches {Policy#decide}. Both call sites were right and neither was
        # redundant, which is exactly the shape that drifts -- a tightening
        # applied to one leaves the other open, and the other is the unattended
        # path. Naming the rule makes "checked exactly once, by whoever holds a
        # queue" a property of the object rather than of a convention.
        #
        # A Stage is a frozen value that takes its queue as an argument
        # ({Epic::Stage#ensure_open!}); this holds the queue because its callers
        # each hold exactly one for the life of a decision.
        class Boundary
          # @param queue [#drained?] the sign-off queue, or {Drained} when the
          #   session has none -- named, never defaulted, for {Policy}'s reason
          def initialize(queue)
            @queue = queue
          end

          # @param stage [#to_s] the stage a gate is about to open at
          # @param epic_slug [#to_s] the epic being walked
          # @return [Epic::Stage] the stage, so the check reads as a precondition
          # @raise [Epic::StageBlocked] when an earlier stage of this epic still
          #   holds sign-offs parked
          # @raise [Epic::UnknownStage] for a stage outside the closed pipeline
          def ensure_open!(stage, epic_slug:) = Epic::Stage.new(stage).ensure_open!(@queue, epic_slug:)
        end

        # @param queue [#drained?] the sign-off queue the stage boundary is
        #   checked against, or {Drained} when the session has none
        def initialize(queue:)
          @queue = queue
          @boundary = Boundary.new(queue)
        end

        # @param artifact [#digest, #gate_question] the thing being gated
        # @param gate [Approval::Gate] the one object that journals and registers
        # @param stage [#to_s] the stage this gate sits on
        # @param epic_slug [#to_s] the epic it belongs to; with `stage`, the
        #   partition key {SignoffQueue} folds decisions on
        # @return [Boolean] whether the artifact was approved
        # @raise [Epic::StageBlocked] when an earlier stage of this epic still
        #   holds sign-offs parked
        def decide(artifact, gate:, stage:, epic_slug:)
          # The stage boundary, checked HERE because this is the seam every gate
          # actually comes through -- a rule only {Epic::Stage} could invoke
          # would be a safety spine nothing walks. Before `gate.call`, so a
          # refusal journals nothing and approves nothing: an epic must not
          # reach implementation on a plan nobody signed off.
          @boundary.ensure_open!(stage, epic_slug:)
          gate.call(artifact, asker: surface, stage:, epic_slug:, policy: name)
        end

        # The journaled label. Read off the subclass's own NAME rather than
        # derived from the class name: these strings are durable journal values
        # and one of them ({Deferred::NAME}) is a fold discriminator, so a rename
        # must break loudly at the constant instead of quietly re-labelling
        # records nobody can join anymore.
        #
        # It is the CONFIGURED name, which for three of the four members is also
        # the label on every record they write. {Adjudicated} is the exception
        # and has to be: it answers `"adjudicated"` here, but a decision it
        # PARKS journals `policy: "deferred"`, because a parked sign-off must
        # wear the discriminator {SignoffQueue}'s fold reads. One policy, two
        # labels, and the record's is the outcome's to choose.
        def name = self.class::NAME

        private

        # @return [#ask] an `ask_human`-shaped duck
        def surface
          raise NotImplementedError, "#{self.class} must answer #surface with an ask_human-shaped duck"
        end
      end

      class Policy
        # The family, reopened after the base class body rather than nested inside
        # it -- the {Effect::Handler} arrangement, and for its reason: a subclass
        # needs its superclass to exist, and defining them after `private` would
        # put class bodies in a section that reads as if it governed them.

        # An asker whose answer is already known: it resolves the promise before
        # handing it back, so {Gate#call}'s await returns at once and no fiber
        # ever parks. A fresh {Lain::Promise} per ask, because resolution is
        # single-shot -- the ANSWER is the constant here, never the promise.
        class StandingAnswer
          def initialize(answer)
            @answer = answer
          end

          def ask(_question) = Promise.new.tap { |promise| promise.resolve(@answer) }
        end

        # The asker-delegating path {Gate} already ships, named. It adds nothing
        # but the label, which is the point: {Gate::DEFAULT_POLICY} is what an
        # un-wrapped call already journals, so wrapping it changes no record.
        class Interactive < Policy
          NAME = Gate::DEFAULT_POLICY

          # @param asker [#ask] the `ask_human`-shaped duck a human answers through
          # @param queue [#drained?] forwarded to {Policy#initialize} -- the
          #   sign-off queue this gate's stage boundary is checked against
          def initialize(asker:, queue:)
            super(queue:)
            @asker = asker
          end

          private

          def surface = @asker
        end

        # Approve immediately -- and AUDIBLY. The verdict still goes through
        # Gate, so an unattended run leaves the same `gate_decision` trail an
        # attended one does, attributed to the policy that gave itself the
        # answer. An approval nobody can point at afterwards would make the run
        # unreviewable, which on a study bench is the same as unrun.
        class HandsOff < Policy
          NAME = "hands_off"
          SURFACE = StandingAnswer.new(Answer.approve(NAME)).freeze

          private

          def surface = SURFACE
        end

        # Refuse now, decide later. The gate is journaled as a real denial
        # (`approved: false`) and parked onto a {SignoffQueue} for human
        # sign-off, so a caller holding an irreversible action still hits
        # {Gate#ensure_approved!} and still refuses -- deferring is not a soft
        # yes, and nothing about it opens a gate.
        #
        # Journal first, park second. The queue is a FOLD of journaled
        # deferrals, so a park with no record behind it would be a claim the
        # rebuild cannot support: it would vanish on restart, and a partition
        # that looks drained opens the next stage's gates. Delegating to Gate
        # first and parking after is what keeps the live queue a subset of the
        # fold -- the same fail-closed ordering, one level up.
        class Deferred < Policy
          NAME = SignoffQueue::DEFERRED_POLICY
          SURFACE = StandingAnswer.new(Answer.deny(NAME)).freeze

          # Parks the refused gate in `@queue` -- the same queue the inherited
          # stage-boundary check reads, because a deferral parks into the very
          # partition a later stage must find drained.
          def decide(artifact, gate:, stage:, epic_slug:)
            approved = super
            @queue.park(artifact_digest: artifact.digest, epic_slug:, stage:,
                        question: artifact.gate_question)
            approved
          end

          private

          def surface = SURFACE
        end

        # Try to answer the question before parking it. The overnight policy:
        # a read-only spike gathers evidence, a second model is asked for a
        # one-word verdict on it, and only a bare APPROVE or DENY settles the
        # gate -- anything less certain refuses and parks for the morning queue
        # with that evidence attached.
        #
        # It is {Adjudicator} wearing the seam `[epics.gates]` selects, and
        # nothing more: the spike, the strict parse, the terminal guard and the
        # journal-then-park ordering all stay there, where they are already
        # specified. {Deferred} is deliberately NOT merged into it and remains
        # the policy that spends no tokens; the two share the queue and nothing
        # else.
        #
        # == It does NOT run the inherited #decide
        #
        # {Policy#decide} checks the stage boundary and then calls the gate.
        # {Adjudicator#call} checks the SAME boundary itself, because it is
        # reachable without a Policy at all, and it calls the gate as one of
        # three possible outcomes. So this overrides `#decide` outright rather
        # than wrapping it: `super` would ask the boundary twice per decision
        # and open the gate on the inherited path before the spike ever ran.
        # Twice was demonstrated with the whole suite green, which is why the
        # counting spec for this shape counts through the POLICY.
        #
        # For the same reason it answers no {Policy#surface}: an adjudicated
        # verdict has no single one. Each {Adjudicator::Outcome} brings the
        # asker its own answer implies, and all of them sign as
        # {Adjudicator::SURFACE}.
        #
        # The inherited `@boundary` is therefore DEAD STATE here, and must stay
        # dead: using it is precisely the double-check above. Only `@queue` is
        # read, and only to hand the Adjudicator the queue it checks against.
        #
        # == Re-deciding a parked address re-spends
        #
        # A deferral settles nothing on purpose ({Adjudicator::AlreadyDecided}
        # guards only terminal verdicts), so an address that parked can be put
        # through this policy again -- and each pass pays two spawns and writes
        # another `gate_evidence`, while the queue still holds one item. Nothing
        # in `lib/` re-decides today; this is the class that makes it reachable
        # from an overnight `[epics.gates]`, so the cost is named rather than
        # discovered on a bill.
        class Adjudicated < Policy
          # The same string as {Adjudicator::TERMINAL_POLICY}, and pinned equal
          # by a spec. Written out rather than referenced because {Adjudicator}
          # loads AFTER this file (gate.rb's manifest), so a forward reference
          # here is a load-time NameError. One string, because "a machine
          # settled this" is one fact whether config is naming the policy or a
          # journal reader is reading the record back.
          NAME = "adjudicated"

          # A journal handle that cannot answer both directions. A {Lain::Error}
          # rather than an ArgumentError because this is the refusal a real
          # wiring hits FIRST -- a plain {Lain::Journal} in the journal slot is
          # the natural mistake -- and every sibling wiring refusal
          # ({Policies::Unknown}, {Policies::MissingSeam}) prints as one clean
          # line through `exe/lain`'s mapping instead of a backtrace.
          class UnreadableJournal < Error; end

          # The invariant nothing downstream can check for itself: the Gate's
          # journal, the evidence journal and the decisions read back must be
          # ONE stream. {Adjudicator::Decided} folds journaled `gate_decision`
          # records to refuse a second terminal verdict, so a read pointed at a
          # different handle answers "nothing was decided" forever -- a guard
          # that never fires, with nothing failing to say so. Requiring one
          # object that answers both directions is what makes the mistake
          # unrepresentable here.
          ONE_JOURNAL = "an adjudicated gate needs one journal handle it can also read back (#record to append, " \
                        "#each to re-walk) -- the terminal-verdict guard folds the decisions this policy " \
                        "itself writes, so a read pointed anywhere else silently never fires"
          private_constant :ONE_JOURNAL

          # @param role_spawn [#call] the `(role, context_mode, prompt) -> Tool::Result`
          #   seam both spawns go through ({Skill::RoleSpawn})
          # @param brief [#call] renders the spike's prompt from the artifact;
          #   required for {Adjudicator}'s reason -- nothing here maps a digest
          #   to a path, so a default could only send the spike after something
          #   it cannot find
          # @param journal [#record, #each] the one handle above. It must ALSO
          #   be the journal the {Approval::Gate} passed to {#decide} writes to,
          #   which no object in this process can check -- a Gate does not
          #   publish its journal. That half of the invariant is the caller's,
          #   and it is what the `deps` value exists to make a session state
          #   once ({Policies::Deps}).
          # @param queue [SignoffQueue] where an uncertain verdict parks -- and
          #   the same queue the stage boundary is read against
          def initialize(role_spawn:, brief:, journal:, queue:)
            raise UnreadableJournal, ONE_JOURNAL unless journal.respond_to?(:record) && journal.respond_to?(:each)

            super(queue:)
            @role_spawn = role_spawn
            @brief = brief
            @journal = journal
          end

          def decide(artifact, gate:, stage:, epic_slug:) = adjudicator(gate).call(artifact, stage:, epic_slug:)

          private

          # Built per decision because the Gate is a decision-time argument on
          # this seam and a constructor-time one there. Nothing is cached with
          # it: {Adjudicator::Decided} re-walks the journal per call by design,
          # so a fresh one costs the fold nothing it was not already paying.
          def adjudicator(gate)
            Adjudicator.new(role_spawn: @role_spawn, gate:, queue: @queue, journal: @journal,
                            brief: @brief, decisions: @journal)
          end
        end
      end
    end
  end
end
