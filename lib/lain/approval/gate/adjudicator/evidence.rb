# frozen_string_literal: true

module Lain
  module Approval
    class Gate
      class Adjudicator
        # {Adjudicator}'s OWN construction contract -- not {Approval::Guards},
        # which carries {GateDecision}'s. Same validate-then-freeze convention:
        # a {Lain::Guard} carrier checked before the auto-frozen Data value
        # exists, so the record never touches ActiveModel and stays
        # `Ractor.shareable?`.
        module Guards
          # All three members that make this record JOINABLE, guarded together.
          # The artifact digest joins a `gate_evidence` line to the
          # `gate_decision` it was reached under; `(epic_slug, stage)` is the
          # partition a review surface reads it back through. A blank one of
          # those still constructs, still journals, and can never be matched
          # back -- which is exactly what {GateDecision} and
          # {SignoffQueue::Partition} both refuse, and this record is read
          # beside them.
          #
          # `digest` is deliberately NOT required: a failed or blank spike
          # journals one of these with a reason and no content address, and that
          # record is the evidence that the gate tried.
          #
          # `latency` is guarded rather than coerced for {GateDecision}'s
          # reason: `to_f` turns nil into 0.0, writing "the spike was instant"
          # -- a measurement nobody made -- into the experiment record.
          class Evidence < Guard
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
        # Content-addressed rather than merely stored: the digest is what rides
        # onto the {GateDecision} and onto the parked {SignoffQueue::Item}, so a
        # reviewer holding either can name the exact evidence text the verdict
        # was reached on. The text is journaled beside it because nothing else
        # stores spike output -- the digest addresses it, this line IS it.
        #
        # `digest` and `text` are nil together exactly when no findings were
        # gathered, and `reason` is populated exactly then. That record is still
        # written: "the gate tried and could not gather" is an experiment result,
        # not an absence.
        #
        # `question` is carried HERE and not only on {SignoffQueue::Item}, whose
        # copy is documented nullable and unrecoverable from the journal. The
        # morning review is question + evidence + hesitation, so a review rebuilt
        # after a restart would otherwise hold the evidence and the model's
        # hesitation and have nothing to say what was being asked.
        #
        # `latency` is the SPIKE's seconds, and it is here because the bench's
        # whole deliverable is comparability: {GateDecision} already journals
        # what the verdict cost, while the spawn that actually spent the tokens
        # journaled nothing. Seconds and not tokens because {Skill::RoleSpawn}
        # hands back a {Tool::Result} with no usage on it -- the child's own turns
        # journal their usage, and a reader joins the two.
        # What "no findings" MEANS, written once.
        #
        # `String#strip` was the first attempt and it is ASCII-ONLY. A spike
        # answering a single U+00A0 satisfied `strip != ""`, was content-
        # addressed, and let a bare APPROVE close the gate on an empty evidence
        # section -- the same fail-open as an empty string, through a narrower
        # door (reproduced end-to-end at `approved=true parked=0` for U+00A0,
        # U+3000, U+2007, U+200B and U+FEFF alike).
        #
        # POSIX `[[:space:]]` is Unicode-aware in Ruby and covers the space
        # separators. The zero-width set is NOT space to any locale and has to
        # be named: U+200B..U+200D, U+2060, U+FEFF.
        #
        # Written out here rather than inside the `Data.define` block, because a
        # constant assigned in that block binds to the enclosing module instead
        # of the Data class (see {Request::SYSTEM_PREFIX} for the same trap).
        NOTHING_AT_ALL = /\A[[:space:]\u{200B}-\u{200D}\u{2060}\u{FEFF}]*\z/
        private_constant :NOTHING_AT_ALL

        GateEvidence = Data.define(:artifact_digest, :epic_slug, :stage, :question, :digest, :text,
                                   :latency, :reason) do
          include Telemetry::Journalable

          # THE blankness test. {Adjudicator#findings} routes on it and
          # {.gathered} refuses on it, so the producer and its own canary cannot
          # drift into disagreeing about what "nothing" is -- which is exactly
          # how the U+00A0 hole got in: two `strip` calls, both wrong, unable to
          # contradict each other.
          #
          # Sharing it makes the canary a second CHECK, not a second OPINION:
          # it cannot catch this class being wrong about blankness, only a
          # caller who skipped the routing. That is the deliberate trade -- a
          # genuinely independent predicate would be a second definition of
          # "nothing", and two definitions are what we just paid for.
          #
          # Undecodable bytes are replaced rather than raised on: a spike that
          # came back as mojibake gathered nothing usable either, so it belongs
          # on the missing arm rather than in an exception.
          def self.blank?(value)
            value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").match?(NOTHING_AT_ALL)
          end

          # The digest is taken from the record's OWN stored text, after
          # construction has clamped it -- not from the argument. That makes
          # "the address names the bytes this line carries" structural rather
          # than a promise: a truncated text cannot end up addressed by the
          # digest of the full one, which would leave `evidence_digest` on a
          # decision naming bytes nobody kept.
          #
          # Blank findings are refused HERE as well as in {Adjudicator#findings},
          # as a canary -- the {SignoffQueue::Guards::Decision} idiom, where a
          # clause no producible value can trip still earns its place.
          # `Canonical.digest("")` is a real address, so a record built this way
          # would answer `gathered?` true and let a bare APPROVE close a gate on
          # nothing. Nothing in this class reaches it today; it is here so a
          # later caller cannot. See {.blank?} for why it shares the predicate
          # rather than restating it.
          def self.gathered(text, gated, latency:)
            raise ArgumentError, "evidence with no findings is missing evidence -- use .missing" if blank?(text)

            record = new(**gated, digest: nil, text:, latency:, reason: nil)
            record.with(digest: Canonical.digest(record.text))
          end

          def self.missing(reason, gated, latency:) = new(**gated, digest: nil, text: nil, latency:, reason:)

          def initialize(artifact_digest:, epic_slug:, stage:, question:, digest:, text:, latency:, reason:)
            # Settled into their journaled bytes BEFORE the guard, so `presence:`
            # judges what actually gets written: a stage object whose #to_s is
            # blank passes a presence check on the raw object and then writes a
            # partition key nothing can match back.
            joinable = { artifact_digest: frozen(artifact_digest), epic_slug: interned(epic_slug),
                         stage: interned(stage) }
            Guards::Evidence.check!(**joinable, latency:)

            super(**joinable, question: clamped(question), digest:, text: text && clamped(text),
                              latency: latency.to_f, reason: frozen(reason))
          end

          def gathered? = !digest.nil?

          private

          # Interned, where the prose is dup'd-and-frozen: the {GateDecision}
          # split, and for its reason -- a stage or an epic repeats across every
          # record in a run, a digest and a spike's findings do not.
          def interned(value) = -value.to_s

          def frozen(value) = value && value.to_s.dup.freeze

          # Bounded because nothing upstream bounds a model's answer, and one
          # runaway spike would put a multi-megabyte line in the middle of an
          # NDJSON experiment record.
          def clamped(value) = value.to_s[0, MAX_TEXT].freeze
        end
      end
    end
  end
end
