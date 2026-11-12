# frozen_string_literal: true

module Lain
  module Epic
    class Gate
      # HOW a verdict is reached, wrapped around the one {Gate} that reaches it.
      #
      # A policy is a SURFACE plus a LABEL, and {#decide} is the whole seam.
      # Nothing here builds a {GateDecision}: Gate journals the one record, and
      # a policy that re-implemented it would be a second copy waiting to disagree.
      #
      # Every policy inherits Gate's reactor precondition, {HandsOff}
      # included, whose approval needs no human. One seam, one precondition, no
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
        # {Epic::Stage}'s boundary rule, bound to the queue it is asked about.
        #
        # It exists because the rule was written TWICE: here on the policy seam,
        # and again inside {Gate::Adjudicator}, which is not a Policy and never
        # reaches {Policy#decide}. Both call sites were right and neither
        # redundant, which is exactly the shape that drifts -- a tightening
        # applied to one leaves the other open, and the other is the unattended
        # path. Naming the rule makes "checked exactly once, by whoever holds a
        # queue" a property of the object rather than of a convention.
        #
        # Research counts as approved only at the bytes research.md holds NOW, and
        # the epic plan only at its structural digest: its issues, edges, titles
        # and criteria. So an edit to either shuts the stages after it again,
        # while the status flips routine work writes into epic.md do not. An
        # issue's own plan is checked at its current digest where its
        # implementation is submitted.
        class Boundary
          # The stages whose approval is read at their current digest.
          FRESH = %w[research epic_plan].freeze

          # The queue as {Epic::Stage} asks it, with research's approval read at its current digest.
          class Current
            # @param queue [#drained?, #approved?, #standing?, #standing] the sign-off queue; this view
            #   adds #missing? from the digests
            # @param digests [#digest] see {Boundary#initialize}
            def initialize(queue, digests)
              @queue = queue
              @digests = digests
            end

            # @return [Boolean] whether nothing is parked where the question reaches
            def drained?(epic_slug, stage, issue_id: nil) = @queue.drained?(epic_slug, stage, issue_id:)

            # @return [Signoff::Standing, nil] the partition's newest settling verdict, whatever bytes it was over
            def standing(epic_slug, stage, issue_id: nil) = @queue.standing(epic_slug, stage, issue_id:)

            # @return [Boolean] whether the stage's artifact is gone, so it has no current digest
            def missing?(epic_slug, stage, issue_id: nil) = @digests.digest(epic_slug, stage, issue_id).nil?

            # @return [Boolean] whether the partition stands approved; for research and the epic plan,
            #   at the current digest, so an artifact that is gone reads as not approved
            def approved?(epic_slug, stage, issue_id: nil)
              return @queue.approved?(epic_slug, stage, issue_id:) unless FRESH.include?(stage.to_s)

              @queue.standing?(@digests.digest(epic_slug, stage, issue_id), epic_slug, stage, issue_id:)
            end
          end
          private_constant :Current

          # @param queue [#drained?, #approved?, #standing?, #standing] the sign-off queue
          # @param digests [#digest] answers `digest(epic_slug, stage, issue_id)` with
          #   that stage's artifact digest as it stands now, or nil where it is gone
          def initialize(queue, digests)
            @queue = Current.new(queue, digests)
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

        # @param queue [#drained?, #approved?, #standing?, #standing, #parked] the sign-off queue
        #   the stage boundary is checked against
        # @param digests [#digest] each earlier artifact's digest as it stands now; see {Boundary}
        def initialize(queue:, digests:)
          @queue = queue
          @digests = digests
          @boundary = Boundary.new(queue, digests)
        end

        # @param artifact [#digest, #gate_question] the thing being gated
        # @param gate [Epic::Gate] the one object that asks and journals
        # @param stage [#to_s] the stage this gate sits on
        # @param epic_slug [#to_s] the epic it belongs to; with `stage`, the
        #   partition key {SignoffQueue} folds decisions on
        # @param issue_id [String, nil] the issue an issue-scoped gate is about;
        #   the third member of that key, nil for an epic-wide stage
        # @param criteria_digest [String, nil] the acceptance criteria the
        #   artifact carries, journaled as the join key a grader reads
        # @return [Boolean, Outcome] whether the artifact was approved, or for a
        #   wave which of its issues were
        # @raise [Epic::StageBlocked] when an earlier stage of this epic still
        #   holds sign-offs parked, or was never approved
        def decide(artifact, gate:, stage:, epic_slug:, issue_id: nil, criteria_digest: nil)
          # Checked HERE because this is the seam every gate actually comes
          # through -- a rule only {Epic::Stage} could invoke would be a safety
          # spine nothing walks. BEFORE `gate.call`, so a refusal journals
          # nothing and approves nothing: an epic must not reach implementation
          # on a plan nobody signed off. A wave is checked issue by issue,
          # before any of them is asked.
          decided(artifact, issue_id, criteria_digest).each do |_item, id, _criteria|
            @boundary.ensure_open!(stage, epic_slug:, issue_id: id)
          end
          gate.call(artifact, asker: surface, stage:, epic_slug:, policy: name, issue_id:, criteria_digest:,
                              interrupted:)
        end

        # Read off the subclass's own NAME rather than derived from the class
        # name: these are durable journal values, so a rename must break loudly
        # at the constant instead of quietly re-labelling records nobody can
        # join anymore.
        #
        # It is the CONFIGURED name. {Adjudicated} and {HandsOff} are the
        # exceptions: each answers its own name here, but a decision it PARKS
        # goes through {Deferred} and journals `policy: "deferred"`.
        def name = self.class::NAME

        private

        # What a wait cancelled before its answer journals: fail-closed, so a deny.
        def interrupted = Approval::Verdict::Deny.new

        # @return [Array<Array(#digest, String, String)>] item, issue and criteria
        def decided(artifact, issue_id, criteria_digest)
          return [[artifact, issue_id, criteria_digest]] unless artifact.respond_to?(:submissions)

          artifact.submissions.map { |submission| [submission, submission.issue_id, submission.criteria_digest] }
        end

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

          def standing? = true
        end

        # The asker-delegating path {Gate} already ships, named. It adds
        # nothing but the label, which is the point: an un-wrapped call already
        # journals {Gate::DEFAULT_POLICY}, so wrapping changes no record.
        class Interactive < Policy
          NAME = Gate::DEFAULT_POLICY

          # @param asker [#ask] the `ask_human`-shaped duck a human answers through
          # @param queue [#drained?, #approved?, #standing?, #standing, #parked] forwarded to
          #   {Policy#initialize} -- the sign-off queue this gate's stage boundary is checked against
          # @param digests [#digest] see {Policy#initialize}
          def initialize(asker:, queue:, digests:)
            super(queue:, digests:)
            @asker = asker
          end

          private

          def surface = @asker
        end

        # Approve immediately -- and AUDIBLY -- unless the issue's acceptance is
        # manual, which is deferred to a human instead. The verdict still goes through
        # Gate, so an unattended run leaves the same `gate_decision` trail an
        # attended one does. An approval nobody can point at afterwards makes
        # the run unreviewable, which on a study bench is the same as unrun.
        class HandsOff < Policy
          NAME = "hands_off"
          SURFACE = StandingAnswer.new(Answer.approve(NAME)).freeze

          # @param queue [#drained?, #approved?, #standing?, #standing, #parked] see {Policy#initialize}
          # @param digests [#digest] see {Policy#initialize}
          # @param journal [#record, nil] where a deferral records its wait; needed only by an issue a human judges
          def initialize(queue:, digests:, journal: nil)
            super(queue:, digests:)
            @deferral = journal && Deferred.new(queue:, digests:, journal:)
          end

          # An issue judged by a human is never approved unseen: it is deferred, so its park and its
          # `awaiting_human` record come from the one policy that owns them.
          def decide(artifact, **scope)
            return super unless artifact.respond_to?(:manual_acceptance?) && artifact.manual_acceptance?

            deferral.decide(artifact, **scope)
          end

          private

          def surface = SURFACE

          def deferral
            @deferral || raise(Error, "a manual acceptance parks for a human, which needs a journal to record the " \
                                      "wait in; build HandsOff with one")
          end
        end

        # Refuse now, decide later: journaled as {GateDecision::Deferred} and
        # parked for human sign-off. It approves nothing, so the partition's
        # {Epic::GateView} reads parked and nothing lands. Deferring is not a soft yes.
        #
        # Journal first, park second. The queue is a FOLD of journaled
        # deferrals, so a park with no record behind it would vanish on restart
        # -- and a partition that looks drained opens the next stage's gates.
        # Delegating to Gate first is what keeps the live queue a subset of the
        # fold.
        class Deferred < Policy
          NAME = SignoffQueue::DEFERRED_POLICY
          SURFACE = StandingAnswer.new(Answer.deferred(NAME)).freeze

          # @param queue [#park] see {Policy#initialize}
          # @param digests [#digest] see {Policy#initialize}
          # @param journal [#record] where the deferred `awaiting_human` lands; required, and it must be
          #   the journal the gate decides into, so the two records sit together
          def initialize(queue:, digests:, journal:)
            super(queue:, digests:)
            @journal = journal
          end

          # The same queue the inherited stage-boundary check reads, because a
          # deferral parks into the very partition a later stage must find
          # drained.
          #
          # A wave parks one item per issue, each with that issue's own question.
          def decide(artifact, gate:, stage:, epic_slug:, issue_id: nil, criteria_digest: nil)
            parked = decided(artifact, issue_id, criteria_digest)
            parked.each { |_item, id, _criteria| Epic::Stage.new(stage).ensure_parkable!(issue_id: id) }
            approved = super
            parked.each do |item, id, criteria|
              @queue.park(artifact_digest: item.digest, epic_slug:, stage:, issue_id: id, criteria_digest: criteria,
                          question: item.gate_question)
              journal_park(item, stage:, epic_slug:, issue_id: id)
            end
            approved
          end

          private

          def surface = SURFACE

          # A park interrupted is still a park: a deny here would revoke the approval it parked beside.
          def interrupted = GateDecision::Deferred.new

          def journal_park(artifact, stage:, epic_slug:, issue_id:)
            sha = artifact.changeset if artifact.respond_to?(:changeset)
            @journal.record(Telemetry::AwaitingHuman.new(kind: "gate", ref: artifact.digest, deferred: true,
                                                         summary: artifact.gate_question, epic_slug:, stage:,
                                                         issue_id:, sha:))
          end
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
          # The same string as {Adjudicator::TERMINAL_POLICY}, written out
          # rather than referenced so a policy does not depend on the
          # adjudicator that happens to end in it, and held equal to it by
          # `spec/lain/epic/gate/policy_spec.rb`.
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
          #   be the journal the {Epic::Gate} passed to {#decide} writes to,
          #   which no object in this process can check -- a Gate does not
          #   publish its journal. That half of the invariant is the CALLER's.
          # @param queue [SignoffQueue] where an uncertain verdict parks -- and
          #   the same queue the stage boundary is read against
          # @param digests [#digest] see {Policy#initialize}
          def initialize(role_spawn:, brief:, journal:, queue:, digests:)
            raise UnreadableJournal, ONE_JOURNAL unless journal.respond_to?(:record) && journal.respond_to?(:each)

            super(queue:, digests:)
            @role_spawn = role_spawn
            @brief = brief
            @journal = journal
          end

          # A wave is adjudicated issue by issue, one spike each, since each
          # issue's verdict is reached on its own evidence.
          def decide(artifact, gate:, stage:, epic_slug:, issue_id: nil, criteria_digest: nil)
            verdicts = decided(artifact, issue_id, criteria_digest).to_h do |item, id, criteria|
              [id, adjudicator(gate).call(item, stage:, epic_slug:, issue_id: id, criteria_digest: criteria)]
            end
            return verdicts.values.first unless artifact.respond_to?(:submissions)

            judged = verdicts.transform_values { _1 ? Approval::Verdict::Approve.new : Approval::Verdict::Deny.new }
            Outcome.new(verdicts: judged, surface: Adjudicator::SURFACE)
          end

          private

          # Built per decision because the Gate is a decision-time argument on
          # this seam and a constructor-time one there. Nothing is cached:
          # {Adjudicator::Decided} re-walks the journal per call by design.
          def adjudicator(gate)
            Adjudicator.new(role_spawn: @role_spawn, gate:, queue: @queue, digests: @digests, journal: @journal,
                            brief: @brief, decisions: @journal)
          end
        end
      end
    end
  end
end
