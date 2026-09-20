# frozen_string_literal: true

module Lain
  module Epic
    # Normalization for {Annotation}, through the unit's own contract: a bespoke
    # validator here could not be re-checked by a reader folding these records
    # back in, which is the whole bargain {Contracts} strikes.
    module AnnotationValue
      def self.interned(epic_slug:, generation:, issue_id:, line:, anchor_text:, text:, drifted: false)
        values = { epic_slug: -epic_slug.to_s, generation: ReviewClaim.generation(generation),
                   issue_id: issue_id && -issue_id.to_s.strip, line: WireInteger.read(line, field: "line"),
                   anchor_text: -anchor_text.to_s, text: -text.to_s, drifted: }
        Contracts::Annotation.check!(**values)

        values
      end
    end
  end
end
