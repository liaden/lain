# frozen_string_literal: true

module Lain
  module Approval
    class Gate
      # HOW a verdict is reached, wrapped around the one {Gate} that reaches it.
      #
      # A policy is a SURFACE plus a LABEL, and {#decide} is the whole seam.
      # Nothing here builds a {GateDecision} or touches the approval registry:
      # Gate journals BEFORE it registers, so a failed journal write can never
      # leave a standing approval behind, and a policy that re-implemented the
      # record would be a second copy of that ordering waiting to disagree.
      #
      # Every policy therefore inherits Gate's reactor precondition, {HandsOff}
      # included, whose answer needs no human. One seam, one precondition, no
      # policy-shaped exception to remember.
      #
      # `answered_by` and `policy` stay independent on the record: {Interactive}
      # journals whichever surface actually spoke, while {HandsOff} and
      # {Deferred} ARE their own surface.
      #
      # {Adjudicated} is the one member that does not fit: it reaches its
      # verdict through {Gate::Adjudicator}, which already owns the boundary
      # check, the gate call and the park, so it overrides {#decide} outright.
      class Policy
        # No sign-off queue in the session at all, so the boundary has nothing
        # to read: naming this opts out of it, every partition drained and
        # approved.
        #
        # NAMED, never defaulted: a policy quietly built without a queue would
        # open every boundary it was supposed to guard, which is the check's own
        # failure mode. Naming this is a statement; forgetting it is an
        # ArgumentError.
        module Drained
          def self.drained?(_epic_slug, _stage, **) = true

          def self.approved?(_epic_slug, _stage, **) = true

          def self.parked(_epic_slug, _stage, **) = []
        end

        # {Epic::Stage}'s boundary rule, bound to the queue it is asked about.
        #
        # It exists because the rule was written TWICE: here on the policy seam,
        # and again inside {Gate::Adjudicator}, which is not a Policy and never
        # reaches {Policy#decide}. Both call sites were right and neither
        # redundant, which is exactly the shape that drifts -- a tightening
        # applied to one leaves the other open, and the other is the unattended
        # path. Naming the rule makes "checked exactly once, by whoever holds a
        # queue" a property of the object rather than of a convention.
        class Boundary
          # @param queue [#drained?, #approved?, #parked] the sign-off queue, or
          #   {Drained} when the session has none -- named, never defaulted, for
          #   {Policy}'s reason
          def initialize(queue)
            @queue = queue
          end

          # @param stage [#to_s] the stage a gate is about to open at
          # @param epic_slug [#to_s] the epic being walked
          # @param issue_id [String, nil] the issue the gate is about, for the
          #   issue-scoped stages; nil checks every issue
          # @return [Epic::Stage] the stage, so the check reads as a precondition
          # @raise [Epic::StageBlocked] when an earlier stage of this epic still
          #   holds sign-offs parked, or was never approved
          # @raise [Epic::UnknownStage] for a stage outside the closed pipeline
          def ensure_open!(stage, epic_slug:, issue_id: nil)
            Epic::Stage.new(stage).ensure_open!(@queue, epic_slug:, issue_id:)
          end
        end

        # @param queue [#drained?, #approved?, #parked] the sign-off queue the stage
        #   boundary is checked against, or {Drained} when the session has none
        def initialize(queue:)
          @queue = queue
          @boundary = Boundary.new(queue)
        end

        # @param artifact [#digest, #gate_question] the thing being gated
        # @param gate [Approval::Gate] the one object that journals and registers
        # @param stage [#to_s] the stage this gate sits on
        # @param epic_slug [#to_s] the epic it belongs to; with `stage`, the
        #   partition key {SignoffQueue} folds decisions on
        # @param issue_id [String, nil] the issue an issue-scoped gate is about;
        #   the third member of that key, nil for an epic-wide stage
        # @param criteria_digest [String, nil] the acceptance criteria the
        #   artifact carries, journaled as the join key a grader reads
        # @return [Boolean] whether the artifact was approved
        # @raise [Epic::StageBlocked] when an earlier stage of this epic still
        #   holds sign-offs parked, or was never approved
        def decide(artifact, gate:, stage:, epic_slug:, issue_id: nil, criteria_digest: nil)
          # Checked HERE because this is the seam every gate actually comes
          # through -- a rule only {Epic::Stage} could invoke would be a safety
          # spine nothing walks. BEFORE `gate.call`, so a refusal journals
          # nothing and approves nothing: an epic must not reach implementation
          # on a plan nobody signed off.
          @boundary.ensure_open!(stage, epic_slug:, issue_id:)
          gate.call(artifact, asker: surface, stage:, epic_slug:, policy: name, issue_id:, criteria_digest:)
        end

        # Read off the subclass's own NAME rather than derived from the class
        # name: these are durable journal values and one ({Deferred::NAME}) is a
        # fold discriminator, so a rename must break loudly at the constant
        # instead of quietly re-labelling records nobody can join anymore.
        #
        # It is the CONFIGURED name. {Adjudicated} is the exception and has to
        # be: it answers `"adjudicated"` here, but a decision it PARKS journals
        # `policy: "deferred"`, because a parked sign-off must wear the
        # discriminator {SignoffQueue}'s fold reads.
        def name = self.class::NAME

        private

        # @return [#ask] an `ask_human`-shaped duck
        def surface
          raise NotImplementedError, "#{self.class} must answer #surface with an ask_human-shaped duck"
        end
      end

      class Policy
        # The family, reopened after the base class body: a subclass needs its
        # superclass to exist, and defining them after `private` would put class
        # bodies in a section that reads as if it governed them.

        # An asker whose answer is already known: it resolves the promise before
        # handing it back, so {Gate#call}'s await returns at once and no fiber
        # parks. A fresh {Lain::Promise} per ask, because resolution is
        # single-shot -- the ANSWER is the constant, never the promise.
        class StandingAnswer
          def initialize(answer)
            @answer = answer
          end

          def ask(_question) = Promise.new.tap { |promise| promise.resolve(@answer) }
        end

        # The asker-delegating path {Gate} already ships, named. It adds
        # nothing but the label, which is the point: an un-wrapped call already
        # journals {Gate::DEFAULT_POLICY}, so wrapping changes no record.
        class Interactive < Policy
          NAME = Gate::DEFAULT_POLICY

          # @param asker [#ask] the `ask_human`-shaped duck a human answers through
          # @param queue [#drained?, #approved?, #parked] forwarded to {Policy#initialize} -- the
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
        # attended one does. An approval nobody can point at afterwards makes
        # the run unreviewable, which on a study bench is the same as unrun.
        class HandsOff < Policy
          NAME = "hands_off"
          SURFACE = StandingAnswer.new(Answer.approve(NAME)).freeze

          private

          def surface = SURFACE
        end

        # Refuse now, decide later: journaled as a REAL denial and parked for
        # human sign-off, so a caller holding an irreversible action still hits
        # {Gate#ensure_approved!} and still refuses. Deferring is not a soft yes.
        #
        # Journal first, park second. The queue is a FOLD of journaled
        # deferrals, so a park with no record behind it would vanish on restart
        # -- and a partition that looks drained opens the next stage's gates.
        # Delegating to Gate first is what keeps the live queue a subset of the
        # fold.
        class Deferred < Policy
          NAME = SignoffQueue::DEFERRED_POLICY
          SURFACE = StandingAnswer.new(Answer.deny(NAME)).freeze

          # The same queue the inherited stage-boundary check reads, because a
          # deferral parks into the very partition a later stage must find
          # drained.
          def decide(artifact, gate:, stage:, epic_slug:, issue_id: nil, criteria_digest: nil)
            approved = super
            @queue.park(artifact_digest: artifact.digest, epic_slug:, stage:, issue_id:, criteria_digest:,
                        question: artifact.gate_question)
            approved
          end

          private

          def surface = SURFACE
        end

        # The overnight policy: a read-only spike gathers evidence, a second
        # model is asked for a one-word verdict on it, and only a bare APPROVE
        # or DENY settles the gate -- anything less certain refuses and parks
        # with that evidence attached. {Deferred} is deliberately NOT merged
        # into it and remains the policy that spends no tokens.
        #
        # == It does NOT run the inherited #decide
        #
        # {Policy#decide} checks the stage boundary and then calls the gate.
        # {Adjudicator#call} checks the SAME boundary itself, because it is
        # reachable without a Policy at all. So this overrides `#decide`
        # outright: `super` would ask the boundary twice per decision AND open
        # the gate on the inherited path before the spike ever ran. That was
        # demonstrated with the whole suite green, which is why the counting
        # spec for this shape counts through the POLICY.
        #
        # For the same reason it answers no {Policy#surface}: an adjudicated
        # verdict has no single one. The inherited `@boundary` is therefore DEAD
        # STATE and must stay dead -- using it is precisely the double-check.
        #
        # == Re-deciding a parked address re-spends
        #
        # A deferral settles nothing on purpose, so an address that parked can
        # be put through this policy again -- and each pass pays two spawns and
        # writes another `gate_evidence` while the queue still holds one item.
        # Nothing in `lib/` re-decides today, so the cost is named here rather
        # than discovered on a bill.
        class Adjudicated < Policy
          # The same string as {Adjudicator::TERMINAL_POLICY}, pinned equal by a
          # spec. Written out rather than referenced because {Adjudicator} loads
          # AFTER this file, so a forward reference is a load-time NameError.
          NAME = "adjudicated"

          # A {Lain::Error} rather than an ArgumentError because this is the
          # refusal a real wiring hits FIRST, and every sibling wiring refusal
          # prints as one clean line through `exe/lain`'s mapping instead of a
          # backtrace.
          class UnreadableJournal < Error; end

          # The invariant nothing downstream can check for itself: the Gate's
          # journal, the evidence journal and the decisions read back must be
          # ONE stream. {Adjudicator::Decided} folds journaled `gate_decision`
          # records to refuse a second terminal verdict, so a read pointed at a
          # different handle answers "nothing was decided" FOREVER -- a guard
          # that never fires, with nothing failing to say so.
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
          #   publish its journal. That half of the invariant is the CALLER's.
          # @param queue [SignoffQueue] where an uncertain verdict parks -- and
          #   the same queue the stage boundary is read against
          def initialize(role_spawn:, brief:, journal:, queue:)
            raise UnreadableJournal, ONE_JOURNAL unless journal.respond_to?(:record) && journal.respond_to?(:each)

            super(queue:)
            @role_spawn = role_spawn
            @brief = brief
            @journal = journal
          end

          def decide(artifact, gate:, stage:, epic_slug:, issue_id: nil, criteria_digest: nil)
            adjudicator(gate).call(artifact, stage:, epic_slug:, issue_id:, criteria_digest:)
          end

          private

          # Built per decision because the Gate is a decision-time argument on
          # this seam and a constructor-time one there. Nothing is cached:
          # {Adjudicator::Decided} re-walks the journal per call by design.
          def adjudicator(gate)
            Adjudicator.new(role_spawn: @role_spawn, gate:, queue: @queue, journal: @journal,
                            brief: @brief, decisions: @journal)
          end
        end
      end
    end
  end
end
