# frozen_string_literal: true

module Lain
  module Approval
    class Gate
      # The attempt a deferred gate makes to answer ITSELF before it parks:
      # spike first, adjudicate second, park only on doubt.
      #
      # {#call} runs two spawns through the injected {Skill::RoleSpawn} seam --
      # `researcher` gathers evidence about the artifact, then `gate_adjudicator`
      # (a sibling of `auto_approver`, same read-only capabilities, its own
      # persona) is handed the gate's question plus that evidence and must answer
      # with ONE word. A clean APPROVE or DENY settles the gate terminally,
      # carrying the evidence's content address on the record. Anything else
      # parks onto the {SignoffQueue} with that same digest attached, so the
      # morning review reads the question, the spike's findings, and the model's
      # hesitation together instead of a bare "deferred".
      #
      # == Every route that is not a bare verdict is a park
      #
      # This class decides when a machine may approve with no human present, so
      # its default arm is the refusal. Prose around the word, an unrecognized
      # word, an error result, a spawn that raised -- all of them reach
      # {#call}'s deferral arm, and only `/\Aapprove\.?\z/i` (or `deny`) leaves
      # it. The strict parse IS the safety property: a model that felt the need
      # to explain itself was not certain, and hesitation must cost a park, never
      # an approval.
      #
      # A FAILED SPIKE SHORT-CIRCUITS. When the researcher raises, comes back an
      # error, or comes back BLANK, the verdict spawn never happens at all --
      # there is nothing to adjudicate on, and asking a model to judge an
      # artifact on no evidence is exactly the shape that produces a confident
      # wrong answer. The item parks with an error note naming the failure. The
      # blank case is the one that matters most in practice: a model returning
      # nothing is far likelier than one that raises, and `Canonical.digest("")`
      # is a real address, so "did we gather any" cannot be a nil check.
      #
      # == What it does NOT own
      #
      # The record and the registry stay {Gate}'s, reached through the same
      # public {Gate#call} every {Policy} goes through, so the journal-then-
      # register ordering survives here by construction rather than by a second
      # implementation agreeing with the first. The queue is journal-fold-shaped
      # the same way {Policy::Deferred} is: journal first, park second.
      #
      # It DOES check the stage boundary itself ({Epic::Stage#ensure_open!}),
      # before either spawn. This is NOT defence in depth: an Adjudicator is not
      # a {Policy} and never reaches {Policy#decide}, so this call is the ONLY
      # boundary check on this path and deleting it opens a real hole -- an
      # unattended machine approving an implementation-stage artifact while that
      # epic's research sign-offs are still parked. Checking first also means a
      # blocked epic spends no tokens.
      #
      # It is nonetheless a SECOND literal call site of a rule T6 already
      # states, and two copies can drift. Collapsing both into a
      # `Policy::Adjudicated` is a filed follow-up; until it lands, treat the
      # duplication as temporary and change the two together.
      class Adjudicator
        # The catalog role that gives the verdict, and the surface every decision
        # is signed with. One string, so a journal reader can never confuse a
        # machine-adjudicated artifact gate with {AutoSurface}'s tool-call
        # approvals or with a human's.
        ROLE = :gate_adjudicator
        SURFACE = ROLE.to_s

        # The spike. `researcher` is the shipped role with read and web
        # capabilities; it gathers, it never judges.
        EVIDENCE_ROLE = :researcher

        # A fresh root over the shared Store for both spawns: neither child
        # inherits the parent's conversation, so a verdict is reached on the
        # artifact and the evidence alone ({AutoSurface}'s reasoning, same seam).
        CONTEXT_MODE = :fresh

        # The `policy` label a settled adjudication wears. It must NOT be
        # {SignoffQueue::DEFERRED_POLICY}: that string is the fold's park/drain
        # discriminator, so a terminal verdict labelled "deferred" would rebuild
        # as a parked sign-off nobody ever answered.
        TERMINAL_POLICY = "adjudicated"

        # The template's contract is ONE word: the WHOLE stripped answer must be
        # a verdict token (a trailing period tolerated). Deliberately a second
        # copy of {AutoSurface}'s regex rather than a shared constant -- that
        # class gates TOOL CALLS under its own persona and this card leaves it
        # untouched, so the two contracts are separately owned and either may
        # tighten without the other moving.
        VERDICT = /\A(approve|deny|defer)\.?\z/i
        private_constant :VERDICT

        # A model that ignored the one-word contract can answer with anything at
        # all, and `reason` lands verbatim in an NDJSON journal line. Truncated
        # so one runaway answer cannot make the experiment record unreadable;
        # the head is where the hesitation actually is.
        MAX_REASON = 500
        private_constant :MAX_REASON

        # The same bound on the spike's own prose and on the artifact's
        # question. A spike is not length-limited by anything upstream, and one
        # runaway answer would put a multi-megabyte line in the middle of an
        # NDJSON experiment record. Larger than {MAX_REASON} because this text
        # is the evidence a reviewer actually reads, not a discarded verdict.
        MAX_TEXT = 10_000
        private_constant :MAX_TEXT

        NO_EVIDENCE = "the evidence spike failed"
        NO_FINDINGS = "the spike returned no findings"
        NO_VERDICT = "the adjudicator spawn failed"
        HESITATION = "the adjudicator did not answer with a bare verdict"
        private_constant :NO_EVIDENCE, :NO_FINDINGS, :NO_VERDICT, :HESITATION

        # A second terminal verdict over one artifact address, refused.
        #
        # {Gate}'s approval registry is ADD-ONLY -- a later denial does not
        # revoke a standing approval -- so an APPROVE followed by a DENY over one
        # digest would leave the journal's terminal record saying `approved:
        # false` while {Gate#approved?} still answers true, and an irreversible
        # caller would proceed on a gate the record shows refused. {SignoffQueue}
        # documents its own drift in the direction that REFUSES; this one drifts
        # the other way. This class is the first path that can re-run a gate with
        # nobody watching, so it refuses loudly rather than documenting it.
        #
        # SCOPE, exactly: the guard is PER-ADJUDICATOR. A second Adjudicator over
        # the same {Gate} re-adjudicates the same address freely, and can journal
        # a denial while `Gate#approved?` still answers true. Closing that needs
        # the registry to answer "has this been DECIDED", which Gate's add-only
        # set of approvals cannot do for a denial without new state -- a design
        # change to a landed, mutation-tested class, filed as a ticket beside
        # `Policy::Adjudicated`. Do not read this guard as stronger than one
        # instance.
        class AlreadyDecided < Error; end

        # @param role_spawn [#call] the `(role, context_mode, prompt) -> Tool::Result`
        #   seam ({Skill::RoleSpawn}); injected, so this class depends on the
        #   message and not on how a child is assembled
        # @param gate [Approval::Gate] the one object that journals and registers
        # @param queue [SignoffQueue] where a deferral parks -- and the same
        #   queue the stage-boundary check reads
        # @param journal [#record] where the spike's evidence lands. Required,
        #   not defaulted, for {Gate}'s reason: an unjournaled spike would make
        #   the `evidence_digest` on a decision address bytes nobody kept.
        # @param brief [#call] renders the researcher's prompt from the artifact.
        #   REQUIRED, deliberately undefaulted. The artifact duck {Gate} ships is
        #   `#digest` and `#gate_question` and nothing more, and nothing in this
        #   process maps a digest to a path -- so a default brief could only tell
        #   the spike to "go read" something it cannot locate, and `researcher`
        #   holds no tool that would fail loudly about it. It would come back
        #   with plausible prose about nothing, which then reads as gathered
        #   evidence. A caller must say how its artifacts render; T9's artifact
        #   home is what will supply the real one.
        # @param clock [#call] monotonic seconds, measuring the SPIKE's latency
        #   ({Gate}'s injected-clock idiom, and the same {RunClock::MONOTONIC}
        #   default)
        def initialize(role_spawn:, gate:, queue:, journal:, brief:, clock: RunClock::MONOTONIC)
          @role_spawn = role_spawn
          @gate = gate
          @queue = queue
          @journal = journal
          @brief = brief
          @clock = clock
          # Address => the verdict it settled on. Process-local and add-only,
          # like {Gate}'s own registry, and read only by {#ensure_undecided!}.
          @terminal = {}
        end

        # Spike, adjudicate, settle or park.
        #
        # PRECONDITION: an Async reactor ({Gate#call} parks on the asker's
        # promise), the same one every policy carries.
        #
        # @param artifact [#digest, #gate_question] the thing being gated
        # @param stage [#to_s] the stage this gate sits on
        # @param epic_slug [#to_s] the epic it belongs to
        # @return [Boolean] whether the artifact was approved
        # @raise [AlreadyDecided] when this address already has a terminal
        #   verdict from this Adjudicator
        # @raise [Epic::StageBlocked] when an earlier stage of this epic still
        #   holds sign-offs parked. Both refusals happen before either spawn, so
        #   a refused gate spends no tokens and journals nothing.
        def call(artifact, stage:, epic_slug:)
          gated = admit(artifact, stage:, epic_slug:)
          evidence = gather(artifact, gated)
          settle(artifact, decide(artifact, evidence), evidence, gated)
        end

        private

        # The refusals that must precede any spend, and the identity every
        # record downstream is keyed by.
        def admit(artifact, stage:, epic_slug:)
          ensure_undecided!(artifact.digest)
          Epic::Stage.new(stage).ensure_open!(@queue, epic_slug:)
          { artifact_digest: artifact.digest, epic_slug:, stage:, question: artifact.gate_question }
        end

        def ensure_undecided!(digest)
          raise AlreadyDecided, already_decided(digest) if @terminal.key?(digest)
        end

        def already_decided(digest)
          "artifact #{digest} already has a terminal adjudication (approved: #{@terminal[digest]}) -- " \
            "Gate's approval registry is add-only, so a second verdict would leave it disagreeing " \
            "with the journal"
        end

        def settle(artifact, outcome, evidence, gated)
          approved = @gate.call(artifact, asker: outcome.asker, stage: gated[:stage],
                                          epic_slug: gated[:epic_slug], policy: outcome.policy,
                                          evidence_digest: evidence.digest, reason: outcome.reason)
          outcome.remember(@terminal, gated[:artifact_digest], approved)
          # Journal first, park second -- the queue is a fold of journaled
          # deferrals, so a park with no record behind it vanishes on restart and
          # leaves a partition that reads drained ({Policy::Deferred}'s ordering,
          # for its reason).
          outcome.park(@queue, **gated, evidence_digest: evidence.digest)
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

        # THE MISSING-EVIDENCE TEST IS BLANKNESS, NOT NIL-NESS. `Canonical.digest("")`
        # is a perfectly real address, so a nil check would call an empty spike
        # "gathered", hand the adjudicator a prompt whose evidence section is
        # blank, and let a bare APPROVE close the gate on nothing. A model that
        # returns nothing -- an empty string, whitespace, a non-breaking space,
        # content blocks with no text -- is far likelier than one that raises, so
        # all of them land here beside the error result and the raise.
        #
        # {GateEvidence.blank?} owns what "nothing" means; this method only
        # routes on it. That split is deliberate and was paid for: an ASCII-only
        # test written twice let U+00A0 through both copies at once.
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

        # The strict parse, and the whole safety property: only a lone verdict
        # token settles anything. Everything else -- prose around the word, an
        # unknown word, an error result -- answers :defer and carries the text
        # forward as the hesitation a reviewer reads.
        def parse(result)
          answer = text_of(result).strip
          match = result.ok? && answer.match(VERDICT)
          match ? [match[1].downcase.to_sym, nil] : [:defer, note(HESITATION, answer)]
        end

        # :defer is the DEFAULT arm, not a listed one: an outcome this method
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

# The subtree index (a file with a sibling directory owns its own requires).
# AFTER the class body: the child reopens {Adjudicator} and reads its
# MAX_TEXT, so the class and the constant must already exist.
require_relative "adjudicator/evidence"
require_relative "adjudicator/outcome"
