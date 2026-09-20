# frozen_string_literal: true

module Lain
  module Review
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
      include Declarative

      declare do
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
        # earlier and more tersely -- but {Lain::Declarative} exposes the carrier, so a
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
        # `anchor_text` carries no validation, which is where this parts company
        # with {Epic::Annotation}, deliberately. A blank line in a diff is a real
        # anchorable position -- an added empty line is a change a human may
        # legitimately have an opinion about -- so `""` is kept. And nil is kept:
        # the evidence is read out of the reviewed revision, which may hold no
        # line where the note was placed, and a note is never refused over that.
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
