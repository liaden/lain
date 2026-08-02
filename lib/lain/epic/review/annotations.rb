# frozen_string_literal: true

module Lain
  module Epic
    class Review
      # Resolves each extmark the editor hands back against the document it was
      # placed in: which issue encloses the line, and whether the line still says
      # what the human anchored the note to.
      #
      # The answer is a plain Hash per note, in the shape {Annotation} takes, and
      # nothing here journals: the caller builds the records itself so it can
      # build them BEFORE it writes anything ({Review#settle} says why).
      module Annotations
        module_function

        # ORDER IS THE OUTPUT. Notes are journaled in the order they come back,
        # and the journal's order is the only order any reader gets -- nothing
        # else records which note the human placed first.
        def resolve(annotations, document_bytes)
          lines = document_bytes.lines(chomp: true)
          annotations.map { |annotation| resolve_one(annotation, lines) }
        end

        # A note crosses msgpack from lua, so its keys arrive as Strings, while
        # an in-process caller writes Symbols. One normalization here beats every
        # caller remembering which side of the wire it is on -- and reading only
        # Symbols raised KeyError on every real note, after the settlement had
        # already been journaled.
        #
        # DRIFT is `anchor_text` against the line the number now names: an
        # extmark slides as the human keeps editing, so a note whose anchor is
        # gone points at a line they never pointed at. Attributed to nothing
        # then, because the number is no longer evidence of which issue was
        # meant -- and kept, because their words are the part nobody can
        # reconstruct.
        def resolve_one(annotation, lines)
          note = annotation.transform_keys(&:to_s)
          line = WireInteger.read(note["line"], field: "line")
          anchor_text = note["anchor_text"].to_s
          drifted = lines[line - 1] != anchor_text
          { line:, text: note["text"].to_s, anchor_text:,
            issue_id: drifted ? nil : issue_at(lines, line), drifted: }
        end
        private_class_method :resolve_one

        # Only ever asked about a line whose anchor still matches, so the end of
        # the document needs no bound here: a line past it holds nil, which
        # matches no anchor, and so is drift. Guessing the last heading for a
        # note that fell off the end is what T22 forbids outright.
        def issue_at(lines, line)
          lines.take(line).filter_map { |text| Document::HEADING.match(text)&.[](:id) }.last
        end
        private_class_method :issue_at
      end
    end
  end
end
