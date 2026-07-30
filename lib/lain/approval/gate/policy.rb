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
        def name = self.class::NAME

        private

        # @return [#ask] an `ask_human`-shaped duck
        def surface
          raise NotImplementedError, "#{self.class} must answer #surface with an ask_human-shaped duck"
        end
      end

      # The family, reopened after the base class body rather than nested inside
      # it -- the {Effect::Handler} arrangement, and for its reason: a subclass
      # needs its superclass to exist, and defining them after `private` would
      # put class bodies in a section that reads as if it governed them.
      class Policy
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

          # @param queue [SignoffQueue] where the refused gate parks -- and the
          #   same queue the inherited stage-boundary check reads, because a
          #   deferral parks into the very partition a later stage must find
          #   drained
          def decide(artifact, gate:, stage:, epic_slug:)
            approved = super
            @queue.park(artifact_digest: artifact.digest, epic_slug:, stage:,
                        question: artifact.gate_question)
            approved
          end

          private

          def surface = SURFACE
        end
      end
    end
  end
end
