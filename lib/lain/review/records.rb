# frozen_string_literal: true

module Lain
  module Review
    # The head of a review: which source produced the changeset, what it spans,
    # and the address every later record joins back to.
    #
    # `source` is validated for presence and NOT against a registry of source
    # names. The registry belongs to {Review::Source}, and one of its entries is
    # deletable by design -- a second copy of the set here would have to be
    # edited to remove a capability, which is the drift a shared vocabulary
    # exists to prevent.
    #
    # `base_ref` is the resolved merge base rather than the branch the human
    # named: the two differ the moment the base advances, and every old-side
    # anchor is computed against the merge base.
    ChangesetOpened = Data.define(:source, :base_ref, :head_ref, :digest) do
      include Telemetry::Journalable
      include Guardable

      guard do
        attribute :source
        attribute :base_ref
        attribute :head_ref
        attribute :digest
        validates :source, presence: { message: Wire.refusal("must name what produced the changeset") }
        validates :base_ref, presence: { message: Wire.refusal("must name the resolved merge base") }
        validates :head_ref, presence: { message: Wire.refusal("must name the head under review") }
        validates :digest, presence: { message: Wire.refusal("must address the changeset") }
      end

      def initialize(source:, base_ref:, head_ref:, digest:)
        values = { source: Wire.token(source), base_ref: Wire.token(base_ref),
                   head_ref: Wire.token(head_ref), digest: Wire.token(digest) }
        self.class.check!(**values)

        super(**values)
      end
    end

    class ChangesetOpened
      # Reopened rather than declared inside the `Data.define ... do` block: a
      # constant there is lexically scoped to the enclosing MODULE, not the Data
      # class (the pinned Ruby trap {Request::SYSTEM_PREFIX} records).
      #
      # The discriminator {Telemetry::Journalable} derives from this class's own
      # name, pinned so a rename breaks loudly at the constant instead of quietly
      # re-labelling records nobody can join anymore.
      JOURNAL_TYPE = "changeset_opened"
    end

    # One hunk's reviewed mark, at the only granularity marks are recorded.
    #
    # `hunk_key` carries its own scheme prefix ({Review::Hunk} owns both the
    # scheme and the version in it), so this record stores the key and does not
    # restate its shape: a prefix pattern here would be a second copy of a scheme
    # designed to be changed.
    HunkMarked = Data.define(:hunk_key, :state) do
      include Telemetry::Journalable
      include Guardable

      guard do
        attribute :hunk_key
        attribute :state
        validates :hunk_key, presence: { message: Wire.refusal("must name the hunk that was marked") }
        validates :state, inclusion: { in: MARK_STATES,
                                       message: Wire.refusal("must be one of #{MARK_STATES.join("/")}") }
      end

      def initialize(hunk_key:, state:)
        values = { hunk_key: Wire.token(hunk_key), state: Wire.token(state) }
        self.class.check!(**values)

        super(**values)
      end
    end

    class HunkMarked
      # See {ChangesetOpened::JOURNAL_TYPE}.
      JOURNAL_TYPE = "hunk_marked"
    end

    # The judgement, against the changeset it judged.
    #
    # `changeset_digest` is required rather than implied by position in the
    # journal: a verdict read back without it is a judgement of nothing, and the
    # journal is shared by every review this session ran.
    #
    # Admissibility -- whether an approve may stand over unreviewed hunks -- is
    # NOT decided here. {Review::Verdict::Policy} owns it, because a rule you
    # cannot swap is a rule you cannot experiment with on a bench. This record
    # judges the vocabulary only.
    ReviewVerdict = Data.define(:verdict, :changeset_digest) do
      include Telemetry::Journalable
      include Guardable

      guard do
        attribute :verdict
        attribute :changeset_digest
        # The message names the DECISION rather than the set, because the two
        # call for opposite responses. An agent reading "must be one of approve"
        # concludes the set is too short and widens it; the correct move is to
        # stop, because choosing the vocabulary is not this chunk's to do.
        validates :verdict,
                  inclusion: { in: VERDICTS,
                               message: Wire.refusal(
                                 "must be #{VERDICTS.join("/")} -- the verdict vocabulary is research open " \
                                 "question 3 and unsettled, so this chunk journals only " \
                                 "#{VERDICTS.join("/")}; a second value is a decision taken in " \
                                 "Review::VERDICTS with that question settled, not here"
                               ) }
        validates :changeset_digest, presence: { message: Wire.refusal("must address the changeset it judged") }
      end

      def initialize(verdict:, changeset_digest:)
        values = { verdict: Wire.token(verdict), changeset_digest: Wire.token(changeset_digest) }
        self.class.check!(**values)

        super(**values)
      end
    end

    class ReviewVerdict
      # See {ChangesetOpened::JOURNAL_TYPE}.
      JOURNAL_TYPE = "review_verdict"
    end

    # One note a human left on a changeset: the changeset-shaped sibling of
    # {Epic::Annotation}, which stays as it is. That one is keyed by an epic slug
    # and a review generation over a prose document; this one is keyed by an
    # anchor id over a `(path, side, line)` in a diff.
    #
    # `revision` is the member that sibling has no need of and this one cannot do
    # without (research open question 4b). An annotation authored against one
    # diff and submitted against another is a live defect in tuicr, and the only
    # thing that makes it detectable is the diff the human was looking at being
    # ON the record rather than implied by whatever is on screen at submit time.
    #
    # `id` is the anchor's, generated at creation and REQUIRED here: this record
    # is what a replay restores it from, so a record that omitted it would
    # rebuild an anchor nothing could recognise as the same one.
    #
    # `text` is the human's own words and is the part nobody can reconstruct, so
    # a note with nothing in it is refused rather than journaled as evidence of
    # something.
    AnnotationPlaced = Data.define(:id, :path, :side, :line, :anchor_text, :text, :kind, :drifted,
                                   :revision) do
      include Telemetry::Journalable
      include Guardable

      guard do
        attribute :id
        attribute :path
        attribute :side
        attribute :line
        attribute :anchor_text
        attribute :text
        attribute :kind
        attribute :drifted
        attribute :revision
        validates :id, presence: { message: Wire.refusal("must carry the anchor's id") }
        validates :path, presence: { message: Wire.refusal("must name the file the note is on") }
        validates :side, inclusion: { in: SIDES, message: Wire.refusal("must be one of #{SIDES.join("/")}") }
        # For the READ side, and it is not dead. A record BUILT here never
        # reaches this message -- {Epic::WireInteger} refuses the same values
        # earlier and more tersely -- but {Guardable} exposes the carrier, so a
        # reader folding a journaled record back in re-checks a line that is
        # already an Integer and never passes through WireInteger at all. One
        # declaration serving both sides is the whole point of the guard.
        validates :line, numericality: { only_integer: true, greater_than: 0,
                                         message: Wire.refusal("must be the diff line the note points at") }
        validates :text, presence: { message: Wire.refusal("must carry what the human wrote") }
        validates :kind, inclusion: { in: ANNOTATION_KINDS,
                                      message: Wire.refusal("must be one of #{ANNOTATION_KINDS.join("/")}") }
        # One measure, one boolean: `false` is the answer most notes give, so
        # `presence:` would refuse the common case.
        validates :drifted, inclusion: { in: [true, false], message: Wire.refusal("must be true or false") }
        validates :revision,
                  presence: { message: Wire.refusal("must name the revision the note was authored against") }
        # NOT `presence:`, which is where this parts company with
        # {Epic::Annotation}, deliberately. A blank line in a diff is a real
        # anchorable position -- an added empty line is a change a human may
        # legitimately have an opinion about -- so `""` is kept and only a
        # missing anchor is refused. A prose document has no such line, which is
        # why the sibling can be stricter.
        validates :anchor_text,
                  exclusion: { in: [nil], message: Wire.refusal("must carry the line the note was anchored to") }
      end

      # `drifted` has NO default, unlike {Epic::Annotation}'s. Drift is a
      # measurement -- anchor_text against the line the number now names -- and a
      # measurement nobody took is a different fact from one that came back
      # false. A default would let a caller that never compared journal "did not
      # drift", which is the reading a later audit cannot tell from a real one.
      # Every caller able to place a note has already resolved the anchor, so
      # requiring it costs nothing and refuses the one case that would be a lie.
      def initialize(id:, path:, side:, line:, anchor_text:, text:, kind:, drifted:, revision:)
        values = { id: Wire.token(id), path: Wire.token(path), side: Wire.token(side),
                   line: Epic::WireInteger.read(line, field: "line"),
                   anchor_text: Wire.text(anchor_text), text: Wire.text(text),
                   kind: Wire.token(kind), drifted:, revision: Wire.token(revision) }
        self.class.check!(**values)

        super(**values)
      end
    end

    class AnnotationPlaced
      # See {ChangesetOpened::JOURNAL_TYPE}.
      JOURNAL_TYPE = "annotation_placed"
    end
  end
end
