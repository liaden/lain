# frozen_string_literal: true

module Lain
  module Epic
    # One note a human left on a document while they held it, journaled by
    # {Review#settle} beside the settlement it belongs to.
    #
    # The only epic record carrying a human's own words, which decides everything
    # else about it: `text` is unreconstructable, so a note is never dropped once
    # it exists. `anchor_text` is the line the note was placed on AT THE TIME,
    # kept beside `line` because the two can disagree -- an extmark slides as the
    # human keeps editing, so the number can end up naming a line they never
    # pointed at.
    #
    # `drifted` is that disagreement said out loud. Under it `issue_id` is nil,
    # not because the note belongs to no issue but because the line number is no
    # longer evidence of which one, and guessing would be a reading dressed up as
    # a fact; a reader wanting the note back where it belongs searches for
    # `anchor_text`. `issue_id` is nil for a preamble note too, which is a
    # DIFFERENT fact -- nothing above it to attribute it to -- and `drifted` is
    # what tells the two apart.
    Annotation = Data.define(:epic_slug, :generation, :issue_id, :line, :anchor_text, :text, :drifted) do
      include Telemetry::Journalable

      def initialize(**values) = super(**AnnotationValue.interned(**values))
    end

    class Annotation
      # See {IssueTransition::JOURNAL_TYPE}.
      JOURNAL_TYPE = "annotation"
    end
  end
end
