# frozen_string_literal: true

module Lain
  module Review
    # The notes an editor hands back, turned into the records the journal keeps.
    #
    # ORDER IS THE OUTPUT. Notes are recorded in the order they arrive, and the
    # journal's order is the only order any reader gets -- nothing else records
    # which note the human placed first. So this maps and never sorts, and
    # `48_annotate.lua` keeps a placement sequence rather than leaning on extmark
    # order, which is POSITIONAL: notes placed on lines 40, 12 and 25 come back
    # from `nvim_buf_get_extmarks` as 12, 25, 40, and that reordering is silent.
    #
    # DRIFT ARRIVES ON THE WIRE. It is measured in the editor, at the moment of
    # settling, and this side neither computes it nor second-guesses it -- which
    # is the one thing about this module a reader is most likely to expect
    # otherwise. Drift is the anchor text against the line the number NOW names,
    # and that line lives in the editor's BUFFER: not in the diff a session
    # holds, and not in anything else Ruby has. Measuring it here would mean
    # holding a document nobody downstream is allowed to cache, and comparing
    # against a copy that can disagree with what the human is looking at.
    #
    # That placement is also what satisfies the extmark contract rather than
    # merely coexisting with it. T15's panel measured that a mark inside a
    # rewritten span MOVES rather than invalidates -- `get_extmark_by_id` still
    # answers a position and never reports invalid -- so drift can only ever be
    # a comparison of CONTENT against CONTENT, taken at settle. The editor does
    # exactly that and sends the boolean.
    #
    # So what is left here is refusing a note that reports no measurement at all,
    # which {AnnotationPlaced} does by giving `drifted` no default: a nil value
    # drops its key from a lua table entirely, and an omitted `drifted` is
    # precisely the shape a bookkeeping slip in the editor produces. Defaulted to
    # `false` it would journal "did not drift" for a note nobody compared -- a
    # reading no later audit can tell from a real one.
    #
    # Nothing here journals. The caller builds the records and writes them
    # itself, so it can decide what to do with a refusal BEFORE anything reaches
    # the fd -- the same split {Epic::Review::Annotations} draws.
    module Annotations
      module_function

      # @param notes [Array<Hash>] the editor's notes IN PLACEMENT ORDER, keyed
      #   by String (as a lua table crosses msgpack) or by Symbol (an in-process
      #   caller); each carries `path`, `side`, `line`, `anchor_text`, `text`,
      #   `kind`, `revision` and `drifted`
      # @return [Array<AnnotationPlaced>] in the same order
      # @raise [ArgumentError] if a note is malformed, an omitted or non-boolean
      #   `drifted` included (see {AnnotationPlaced})
      def settle(notes)
        notes.map { |note| place(note.transform_keys(&:to_s)) }
      end

      # The anchor is built FIRST and the record from it, rather than both from
      # the note: the anchor is what mints the id and what judges the position,
      # so a record built beside it could disagree with it about both.
      #
      # The tokens are interned and stripped on the way in and the two text
      # members never are -- the normalization {RpcThread::ReviewWrite} applies
      # to the OTHER review rail, applied here because this rail does not cross
      # that boundary. Without it a `" new "` off the wire misses
      # {Anchor::SIDES} and is refused as a side nothing recognises, while an
      # anchored line's leading indentation is precisely the evidence the
      # editor's drift comparison used -- stripped here, the record would
      # disagree with the measurement it carries.
      def place(note)
        anchor = anchor_for(note)
        AnnotationPlaced.new(id: anchor.id, path: anchor.path, side: anchor.side,
                             line: anchor.line, anchor_text: anchor.anchor_text,
                             text: Wire.text(note["text"]), kind: Wire.token(note["kind"]),
                             drifted: note["drifted"], revision: anchor.revision)
      end
      private_class_method :place

      # The position half of a note, judged. Its own method because the record
      # above and this share nothing but the note they read: this one decides
      # what a valid POSITION is, and gets that decision from {Anchor} rather
      # than restating any of it.
      def anchor_for(note)
        Anchor.new(path: Wire.token(note["path"]), side: Wire.token(note["side"]),
                   line: Epic::WireInteger.read(note["line"], field: "line"),
                   anchor_text: Wire.text(note["anchor_text"]), revision: Wire.token(note["revision"]))
      end
      private_class_method :anchor_for
    end
  end
end
