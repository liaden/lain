# frozen_string_literal: true

module Lain
  module Approval
    class Gate
      # The attempt a deferred gate makes to answer ITSELF before it parks:
      # spike first, adjudicate second, park only on doubt. `researcher` gathers
      # evidence, then `gate_adjudicator` is handed the gate's question plus
      # that evidence and must answer with ONE word.
      #
      # == Every route that is not a bare verdict is a park
      #
      # This class decides when a machine may approve with no human present, so
      # its DEFAULT arm is the refusal. Prose around the word, an unrecognized
      # word, an error result, a spawn that raised -- all reach the deferral
      # arm. The strict parse IS the safety property: a model that felt the need
      # to explain itself was not certain, and hesitation must cost a park,
      # never an approval.
      #
      # A FAILED SPIKE SHORT-CIRCUITS: when the researcher raises, errors, or
      # comes back BLANK, the verdict spawn never happens, because asking a
      # model to judge an artifact on no evidence is the shape that produces a
      # confident wrong answer. The blank case matters most in practice -- a
      # model returning nothing is far likelier than one that raises, and
      # `Canonical.digest("")` is a real address, so "did we gather any" cannot
      # be a nil check.
      #
      # == What it does NOT own
      #
      # The record and the registry stay {Gate}'s, reached through the same
      # public {Gate#call} every {Policy} goes through, so the journal-then-
      # register ordering survives by construction. The queue is
      # journal-fold-shaped the same way {Policy::Deferred} is.
      #
      # It DOES check the stage boundary itself, before either spawn, and that
      # is NOT defence in depth: an Adjudicator is not a {Policy} and never
      # reaches {Policy#decide}, so this check is the ONLY one on this path.
      # Deleting it opens a real hole -- an unattended machine approving an
      # implementation-stage artifact while that epic's research sign-offs are
      # still parked. Checking first also means a blocked epic spends no tokens.
      # It is the same OBJECT the policy seam checks, not a second copy of the
      # rule, so a tightening cannot land on one path and miss this one.
      class Adjudicator
        # One string, so a journal reader can never confuse a
        # machine-adjudicated artifact gate with {AutoSurface}'s tool-call
        # approvals or with a human's.
        ROLE = :gate_adjudicator
        SURFACE = ROLE.to_s

        # The spike. `researcher` gathers; it never judges.
        EVIDENCE_ROLE = :researcher

        # A fresh root for both spawns: neither child inherits the parent's
        # conversation, so a verdict is reached on the artifact and the evidence
        # alone.
        CONTEXT_MODE = :fresh

        # It must NOT be {SignoffQueue::DEFERRED_POLICY}: that string is the
        # fold's park/drain discriminator, so a terminal verdict labelled
        # "deferred" would rebuild as a parked sign-off nobody ever answered.
        TERMINAL_POLICY = "adjudicated"

        # The WHOLE stripped answer must be a verdict token, a trailing period
        # tolerated. Deliberately a SECOND copy of {AutoSurface}'s regex rather
        # than a shared constant: that class gates TOOL CALLS under its own
        # persona, so the two contracts are separately owned and either may
        # tighten without the other moving.
        VERDICT = /\A(approve|deny|defer)\.?\z/i
        private_constant :VERDICT

        # A model that ignored the one-word contract can answer with anything,
        # and `reason` lands verbatim in an NDJSON journal line. Truncated so
        # one runaway answer cannot make the experiment record unreadable; the
        # head is where the hesitation actually is.
        MAX_REASON = 500
        private_constant :MAX_REASON

        # A spike is not length-limited by anything upstream, and one runaway
        # answer would put a multi-megabyte line in an NDJSON record. Larger
        # than {MAX_REASON} because this text is the evidence a reviewer
        # actually reads, not a discarded verdict.
        MAX_TEXT = 10_000
        private_constant :MAX_TEXT

        NO_EVIDENCE = "the evidence spike failed"
        NO_FINDINGS = "the spike returned no findings"
        NO_VERDICT = "the adjudicator spawn failed"
        HESITATION = "the adjudicator did not answer with a bare verdict"
        private_constant :NO_EVIDENCE, :NO_FINDINGS, :NO_VERDICT, :HESITATION

        # A second terminal verdict over one artifact address, refused.
        #
        # {Gate}'s registry is ADD-ONLY, so an APPROVE followed by a DENY over
        # one digest would leave the journal's terminal record saying
        # `approved: false` while {Gate#approved?} still answers true -- and an
        # irreversible caller would proceed on a gate the record shows refused.
        # This class is the first path that can re-run a gate with nobody
        # watching, so it refuses loudly. It also closes the RATCHET the other
        # way: without it, a terminal DENY could be re-run until some spike
        # happened to produce evidence a verdict approved on.
        #
        # SCOPE, exactly: the guard is over the JOURNAL rather than one object's
        # memory, so it holds across Adjudicators and sessions -- but it is a
        # SEQUENTIAL guarantee only. Forced rather than generous: the registry
        # answers "was this APPROVED", which a terminal denial leaves false, so
        # an add-only set cannot answer "was this DECIDED". The journal can. A
        # deferral is deliberately NOT terminal: parking is an invitation to
        # come back.
        #
        # WHAT IT DOES NOT COVER: this is check-then-act and the window is WIDE
        # -- {#admit} folds the journal, TWO model round-trips run, then
        # {#settle} writes. Two Adjudicators over one address concurrently both
        # pass the check before either writes, and both journal a terminal
        # verdict; reproduced under `Async`, one `approved: true` and one
        # `approved: false` for the same digest. Closing it needs
        # compare-and-append, which the Journal has no primitive for. Until
        # then: one Adjudicator per address at a time.
        class AlreadyDecided < Error; end

        # Which artifact addresses a machine has already SETTLED, read off the
        # journal.
        #
        # A FOLD rather than a set: the record is the state, so two readers of
        # one journal agree by construction. RE-WALKED per lookup rather than
        # indexed once, because the whole question is whether somebody ELSE --
        # another Adjudicator, another session -- settled this address since we
        # last looked, which a snapshot cannot answer.
        #
        # {Adjudicator::TERMINAL_POLICY} is the discriminator and the only
        # honest one available: {Gate}'s registry is add-only, so it answers
        # "was this APPROVED" and leaves a terminal DENIAL looking exactly like
        # an artifact nobody judged. A `deferred` record is deliberately NOT
        # terminal -- parking is an invitation to come back.
        #
        # == The identity is the DIGEST ALONE
        #
        # `(epic_slug, stage)` is on every record, so ignoring it here is a
        # decision: one address adjudicated in `alpha/epic_plan` refuses the
        # same CONTENT in `beta/research`, permanently, with no override short
        # of editing the journal. Chosen because it fails CLOSED and because it
        # is the identity {Gate#approved?} already uses -- an approval carries
        # across partitions, so a partition-scoped refusal could disagree with a
        # global approval, the exact disagreement {AlreadyDecided} prevents.
        #
        # It stops mattering as submissions arrive pre-qualified:
        # `Submission#digest` addresses `{stage, slug, artifact}`, so the same
        # artifact in two partitions is already two addresses.
        class Decided
          # A nil `decisions:` builds cleanly and then dies INSIDE the fold --
          # mid-decision, after both spawns are paid for, naming neither the
          # argument nor the caller that omitted it. Refused where the mistake
          # was made.
          MISSING = "Decided needs the journal read back -- the Journal.records duck (an Enumerable of parsed " \
                    "Hashes or raw NDJSON lines), got nil. There is no 'nothing was decided' default."
          private_constant :MISSING

          # @param entries [Enumerable<Hash, String>] the {Journal.records} duck
          #   -- parsed Hashes or raw NDJSON lines -- RE-ENUMERATED on every
          #   lookup. The two Enumerator shapes are not interchangeable:
          #   `File.foreach(path)` (no block) re-opens the file per walk and is
          #   correct; `File.open(path).each_line` and `io.each_line` are
          #   one-shot, so a second lookup answers "nothing decided" and the
          #   guard fails OPEN. An Array snapshot is one-shot in the same way --
          #   it cannot contain the record this decision is about to write.
          def initialize(entries)
            raise ArgumentError, MISSING if entries.nil?

            @entries = entries
          end

          # The precondition {Adjudicator#call} runs before it spends anything.
          #
          # @param digest [String] the artifact address about to be judged
          # @return [nil] when no machine has settled this address
          # @raise [AlreadyDecided] naming the address and the verdict it
          #   already carries
          def ensure_undecided!(digest)
            settled = self[digest]
            raise AlreadyDecided, refusal(digest, settled) if settled
          end

          private

          # The LAST match, not the first. Which record refuses does not matter
          # -- any terminal one does -- but which the MESSAGE names does: two
          # conflicting terminal records for one address are reachable through
          # the concurrent window {AlreadyDecided} documents, and journal order
          # is time order, so the last written is the one that stands.
          def [](digest)
            Journal.records(@entries, type: SignoffQueue::JOURNAL_TYPE)
                   .select { |record| terminal?(record, digest) }
                   .to_a.last
          end

          def terminal?(record, digest)
            record["policy"].to_s == TERMINAL_POLICY && record["artifact_digest"].to_s == digest.to_s
          end

          def refusal(digest, settled)
            "artifact #{digest} already has a terminal adjudication (approved: #{settled["approved"]}) -- " \
              "Gate's approval registry is add-only, so a second verdict would leave it disagreeing " \
              "with the journal"
          end
        end

        # {Adjudicator}'s OWN construction contract, not {Approval::Contracts}.
        module Contracts
          # The three members that make this record JOINABLE, guarded together:
          # a blank one still constructs, still journals, and can never be
          # matched back to the `gate_decision` it was reached under.
          #
          # `digest` is deliberately NOT required: a failed or blank spike
          # journals one of these with a reason and no content address, and that
          # record is the evidence that the gate TRIED.
          #
          # `latency` is guarded rather than coerced: `to_f` turns nil into 0.0,
          # writing "the spike was instant" -- a measurement nobody made -- into
          # the experiment record.
          class Evidence < Declarative::Carrier
            attribute :artifact_digest
            attribute :epic_slug
            attribute :stage
            attribute :latency
            validates :artifact_digest, presence: { message: "must name the artifact it was gathered about, got nil" }
            validates :epic_slug, presence: { message: "must name the epic it belongs to, got nil" }
            validates :stage, presence: { message: "must name the stage it was gathered at, got nil" }
            validates :latency, numericality: { greater_than_or_equal_to: 0,
                                                message: "must be seconds >= 0, got %<value>s" }
          end
        end

        # One spike's findings over one artifact, journaled as `gate_evidence`.
        #
        # Content-addressed rather than merely stored: the digest rides onto the
        # {GateDecision} and the parked {SignoffQueue::Item}, so a reviewer
        # holding either can name the exact evidence text the verdict was
        # reached on. The text is journaled beside it because nothing else
        # stores spike output -- the digest addresses it, this line IS it.
        #
        # `digest` and `text` are nil together exactly when nothing was
        # gathered, and `reason` is populated exactly then. That record is still
        # written: "the gate tried and could not gather" is an experiment
        # result, not an absence.
        #
        # `question` is carried HERE and not only on {SignoffQueue::Item}, whose
        # copy is nullable and unrecoverable from the journal -- otherwise a
        # review rebuilt after a restart would hold the evidence and the model's
        # hesitation with nothing to say what was being asked.
        #
        # `latency` is the SPIKE's seconds: {GateDecision} already journals what
        # the verdict cost, while the spawn that spent the tokens journaled
        # nothing. Seconds and not tokens because {Skill::RoleSpawn} hands back a
        # {Tool::Result} with no usage on it; the child's own turns journal
        # theirs, and a reader joins the two.
        GateEvidence = Data.define(:artifact_digest, :epic_slug, :stage, :question, :digest, :text,
                                   :latency, :reason) do
          include Telemetry::Journalable

          # THE blankness test. {Adjudicator#findings} routes on it and
          # {.gathered} refuses on it, so the producer and its canary cannot
          # drift about what "nothing" is -- which is how the U+00A0 hole got
          # in: two `strip` calls, both wrong, unable to contradict each other.
          #
          # Sharing makes the canary a second CHECK, not a second OPINION: it
          # cannot catch this class being wrong about blankness, only a caller
          # who skipped the routing. The deliberate trade, since a genuinely
          # independent predicate would be a second definition of "nothing".
          #
          # The predicate lives in {Lain::Blankness}, below both this and
          # {Question::Answer}, rather than one unit reaching up into the other.
          def self.blank?(value) = Blankness.blank?(value)

          # The digest is taken from the record's OWN stored text, AFTER
          # construction clamped it, never from the argument. That makes "the
          # address names the bytes this line carries" structural rather than a
          # promise: a truncated text cannot end up addressed by the digest of
          # the full one, leaving `evidence_digest` naming bytes nobody kept.
          #
          # Blank findings are refused here as well as in {Adjudicator#findings},
          # as a CANARY. `Canonical.digest("")` is a real address, so a record
          # built this way would answer `gathered?` true and let a bare APPROVE
          # close a gate on nothing. Nothing reaches it today; it is here so a
          # later caller cannot.
          def self.gathered(text, gated, latency:)
            raise ArgumentError, "evidence with no findings is missing evidence -- use .missing" if blank?(text)

            record = new(**gated, digest: nil, text:, latency:, reason: nil)
            record.with(digest: Canonical.digest(record.text))
          end

          def self.missing(reason, gated, latency:) = new(**gated, digest: nil, text: nil, latency:, reason:)

          def initialize(artifact_digest:, epic_slug:, stage:, question:, digest:, text:, latency:, reason:)
            # Settled into their journaled bytes BEFORE the guard, so
            # `presence:` judges what actually gets written: a stage whose #to_s
            # is blank passes a presence check on the raw object and then writes
            # a partition key nothing can match back.
            joinable = { artifact_digest: frozen(artifact_digest), epic_slug: interned(epic_slug),
                         stage: interned(stage) }
            Contracts::Evidence.check!(**joinable, latency:)

            super(**joinable, question: clamped(question), digest:, text: text && clamped(text),
                              latency: latency.to_f, reason: frozen(reason))
          end

          def gathered? = !digest.nil?

          private

          # Interned where the prose is dup'd-and-frozen: a stage or an epic
          # repeats across every record in a run, a digest and a spike's
          # findings do not.
          def interned(value) = -value.to_s

          def frozen(value) = value && value.to_s.dup.freeze

          # Nothing upstream bounds a model's answer, and one runaway spike
          # would put a multi-megabyte line in an NDJSON experiment record.
          def clamped(value) = value.to_s[0, MAX_TEXT].freeze
        end

        # WHAT a verdict does, as two objects rather than a branch at the call
        # site. This class IS the terminal outcome: it settles the address and
        # parks nothing; {Deferral} inverts both. Splitting them rather than
        # testing a symbol keeps "a deferral never settles" and "a terminal
        # verdict never parks" single statements instead of two conditionals
        # that could disagree.
        class Outcome
          attr_reader :policy, :reason

          def initialize(answer:, policy:, reason:)
            @answer = answer
            @policy = policy
            @reason = reason
          end

          # The answer is already known, so {Policy::StandingAnswer} resolves
          # the promise up front and no fiber parks.
          def asker = Policy::StandingAnswer.new(@answer)

          # A terminal verdict has nothing awaiting sign-off, so the caller
          # never asks whether to enqueue.
          def park(_queue, **) = nil

          # Remembered, so a second adjudication over this address is refused.
          def remember(terminal, digest, approved) = terminal[digest] = approved
        end

        # Doubt, in every form it arrives in. It parks and settles NOTHING: a
        # deferral is an invitation to come back, so re-running the same address
        # later must stay allowed -- exactly the case {AlreadyDecided} must not
        # catch.
        class Deferral < Outcome
          def park(queue, **attributes) = queue.park(**attributes)

          def remember(_terminal, _digest, _approved) = nil
        end

        # @param role_spawn [#call] the `(role, context_mode, prompt) -> Tool::Result`
        #   seam ({Skill::RoleSpawn}); injected, so this class depends on the
        #   message and not on how a child is assembled
        # @param gate [Approval::Gate] the one object that journals and registers
        # @param queue [SignoffQueue] where a deferral parks -- and the same
        #   queue the stage-boundary check reads
        # @param journal [#record] where the spike's evidence lands. Required,
        #   not defaulted: an unjournaled spike would make the `evidence_digest`
        #   on a decision address bytes nobody kept.
        # @param brief [#call] renders the researcher's prompt from the
        #   artifact. REQUIRED and deliberately undefaulted: the artifact duck
        #   is `#digest` and `#gate_question` and nothing more, and nothing in
        #   this process maps a digest to a path -- so a default brief could
        #   only tell the spike to "go read" something it cannot locate, and
        #   `researcher` holds no tool that would fail loudly about it. It would
        #   come back with plausible prose about nothing, which then reads as
        #   gathered evidence.
        # @param decisions [Enumerable<Hash, String>] the journal read BACK,
        #   which {Decided} folds for terminal adjudications. Required and
        #   undefaulted: defaulting it would answer "nothing was decided" for a
        #   session that simply was not wired, the permissive answer to the one
        #   question this guard refuses on. Pass something RE-READABLE
        #   (`File.foreach(path)` re-opens per walk); a snapshot Array taken at
        #   construction goes stale at the first decision.
        # @param clock [#call] monotonic seconds, measuring the SPIKE's latency
        def initialize(role_spawn:, gate:, queue:, journal:, brief:, decisions:, clock: RunClock::MONOTONIC)
          @role_spawn = role_spawn
          @gate = gate
          @queue = queue
          @journal = journal
          @brief = brief
          @decided = Decided.new(decisions)
          @clock = clock
          @boundary = Policy::Boundary.new(queue)
        end

        # Spike, adjudicate, settle or park.
        #
        # PRECONDITION: an Async reactor, since {Gate#call} parks on the asker's
        # promise.
        #
        # @param artifact [#digest, #gate_question] the thing being gated
        # @param stage [#to_s] the stage this gate sits on
        # @param epic_slug [#to_s] the epic it belongs to
        # @param issue_id [String, nil] the issue an issue-scoped gate is about
        # @param criteria_digest [String, nil] the criteria the artifact carries
        # @return [Boolean] whether the artifact was approved
        # @raise [AlreadyDecided] when the journal already holds a terminal
        #   adjudication of this address, whichever way it went
        # @raise [Epic::StageBlocked] when an earlier stage of this epic still
        #   holds sign-offs parked. Both refusals happen before either spawn, so
        #   a refused gate spends no tokens and journals nothing.
        def call(artifact, stage:, epic_slug:, issue_id: nil, criteria_digest: nil)
          gated = admit(artifact, stage:, epic_slug:, issue_id:)
          evidence = gather(artifact, gated)
          settle(artifact, decide(artifact, evidence), evidence, gated, issue_id:, criteria_digest:)
        end

        private

        # Two named preconditions, each owned by the object that knows its
        # rule, both before any spend. The BOUNDARY goes first only because of
        # what an operator can do about it: a blocked epic names sign-offs
        # somebody can go approve, where "already decided" is a dead end. This
        # order is a diagnosis choice, not a safety one.
        #
        # The answer is exactly what {GateEvidence} is built from, so the
        # issue scope rides beside it into {#settle} rather than inside it.
        def admit(artifact, stage:, epic_slug:, issue_id:)
          @boundary.ensure_open!(stage, epic_slug:, issue_id:)
          @decided.ensure_undecided!(artifact.digest)
          { artifact_digest: artifact.digest, epic_slug:, stage:, question: artifact.gate_question }
        end

        def settle(artifact, outcome, evidence, gated, **scope)
          approved = @gate.call(artifact, asker: outcome.asker, stage: gated[:stage],
                                          epic_slug: gated[:epic_slug], policy: outcome.policy,
                                          evidence_digest: evidence.digest, reason: outcome.reason, **scope)
          # Journal first, park second: the queue is a fold of journaled
          # deferrals, so a park with no record behind it vanishes on restart
          # and leaves a partition that reads drained.
          outcome.park(@queue, **gated, **scope, evidence_digest: evidence.digest)
          approved
        end

        def gather(artifact, gated)
          evidence = spike(artifact, gated)
          @journal.record(evidence)
          evidence
        end

        def spike(artifact, gated)
          started = @clock.call
          result = @role_spawn.call(EVIDENCE_ROLE, CONTEXT_MODE, @brief.call(artifact))
          findings(result, gated, latency: @clock.call - started)
        rescue StandardError => e
          GateEvidence.missing(note(NO_EVIDENCE, "#{e.class}: #{e.message}"), gated,
                               latency: @clock.call - started)
        end

        # THE MISSING-EVIDENCE TEST IS BLANKNESS, NOT NIL-NESS.
        # `Canonical.digest("")` is a perfectly real address, so a nil check
        # would call an empty spike "gathered", hand the adjudicator a prompt
        # whose evidence section is blank, and let a bare APPROVE close the gate
        # on nothing.
        #
        # {GateEvidence.blank?} owns what "nothing" means; this method only
        # routes on it. That split was paid for: an ASCII-only test written
        # twice let U+00A0 through both copies at once.
        def findings(result, gated, latency:)
          text = text_of(result)
          return GateEvidence.gathered(text, gated, latency:) if result.ok? && !GateEvidence.blank?(text)

          GateEvidence.missing(note(NO_EVIDENCE, result.ok? ? NO_FINDINGS : text), gated, latency:)
        end

        # No evidence, no verdict: the adjudicator is never asked to judge an
        # artifact it was given nothing about.
        def decide(artifact, evidence)
          return outcome(:defer, evidence.reason) unless evidence.gathered?

          outcome(*verdict(artifact, evidence))
        end

        def verdict(artifact, evidence)
          parse(@role_spawn.call(ROLE, CONTEXT_MODE, question(artifact, evidence)))
        rescue StandardError => e
          [:defer, note(NO_VERDICT, "#{e.class}: #{e.message}")]
        end

        # The whole safety property: only a LONE verdict token settles
        # anything. Everything else answers :defer and carries the text forward
        # as the hesitation a reviewer reads.
        def parse(result)
          answer = text_of(result).strip
          match = result.ok? && answer.match(VERDICT)
          match ? [match[1].downcase.to_sym, nil] : [:defer, note(HESITATION, answer)]
        end

        # :defer is the DEFAULT arm, never a listed one: an outcome this method
        # does not recognize can only become a park.
        def outcome(verdict, reason)
          case verdict
          when :approve then Outcome.new(answer: Answer.approve(SURFACE), policy: TERMINAL_POLICY, reason: nil)
          when :deny then Outcome.new(answer: Answer.deny(SURFACE), policy: TERMINAL_POLICY, reason: nil)
          else Deferral.new(answer: Answer.deny(SURFACE), policy: SignoffQueue::DEFERRED_POLICY, reason:)
          end
        end

        def note(headline, detail) = "#{headline}: #{detail.to_s[0, MAX_REASON]}"

        def text_of(result)
          content = result.content
          content.is_a?(String) ? content : content.filter_map { |block| block["text"] }.join("\n")
        end

        def question(artifact, evidence)
          <<~PROMPT
            An artifact is waiting on an approval gate. Judge it against the evidence below and
            answer with exactly one word.

            artifact: #{artifact.digest}

            the gate's question:
            #{artifact.gate_question}

            the evidence gathered for you:
            #{evidence.text}

            Answer APPROVE only if the evidence plainly shows the artifact answers its question,
            DENY if it plainly does not, and DEFER if you are not sure or the evidence does not
            cover it. When in doubt, DEFER -- never approve on doubt.
          PROMPT
        end
      end
    end
  end
end
