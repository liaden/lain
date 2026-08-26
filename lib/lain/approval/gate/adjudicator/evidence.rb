# frozen_string_literal: true

module Lain
  module Approval
    class Gate
      class Adjudicator
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
      end
    end
  end
end
