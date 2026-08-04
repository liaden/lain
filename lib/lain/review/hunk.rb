# frozen_string_literal: true

module Lain
  module Review
    Hunk = Data.define(:path, :old_start, :old_count, :new_start, :new_count, :heading, :lines)

    # One hunk of a unified diff, and the key that carries its reviewed state
    # from one regeneration of that diff to the next.
    #
    # The key hashes the hunk's own text -- origin markers included, the `@@`
    # header excluded -- so an edit above a hunk renumbers the header without
    # clearing the mark. `Canonical` is deliberately not used: a hunk body is
    # already bytes, and routing it through a JSON-native canonicalization would
    # normalize away differences the key exists to keep.
    #
    # Keys are derivable on the MAIN Ractor only. A Hunk is shareable, but
    # `Ext.blake3_hex` is not ractor-safe -- the same recorded gap Fuzzy and
    # Bm25 carry, pinned in the spec rather than left to be rediscovered.
    #
    # The body is a REOPENED class rather than a `Data.define` block, because a
    # constant declared inside that block lands on the enclosing module instead,
    # out of reach of the methods that resolve it.
    class Hunk
      CONTENT_SCHEME = "hunk-content-v1"
      SPAN_SCHEME = "hunk-span-v1"

      # The review keys for a WHOLE changeset's hunks, in the order given. The
      # batch is a precondition, not a convenience: a hunk cannot tell on its own
      # that it is duplicated, so keying one at a time hands two byte-identical
      # hunks the same key -- reviewed state on unreviewed code.
      #
      # Duplicates fall back to a span-qualified key. An occurrence count would
      # move that state onto the wrong duplicate the moment one of them changed.
      # The old-side span moves only when the BASE moves, so a mark survives the
      # author's own edits above it; measured over 66k real `git diff` runs, no
      # two hunks of one file ever shared it. Where it does tie -- a shape git
      # does not emit but this value object permits -- the full span breaks the
      # tie, so no two hunks can ever share a key.
      def self.keys(hunks)
        content = hunks.map(&:content_key)
        duplicated = content.tally
        spanned = hunks.zip(content).map { |hunk, key| duplicated[key] > 1 ? hunk.span_key : key }
        tied = spanned.tally
        hunks.zip(spanned).map { |hunk, key| tied[key] > 1 ? hunk.full_span_key : key }.freeze
      end

      # `to_str` rather than `to_s`, to match the loudness of the `Integer()`
      # beside it: a nil path must raise here, not address as the empty string.
      def initialize(path:, old_start:, old_count:, new_start:, new_count:, lines:, heading: "")
        super(path: -path.to_str, old_start: Integer(old_start), old_count: Integer(old_count),
              new_start: Integer(new_start), new_count: Integer(new_count),
              heading: -heading.to_str, lines: lines.map { -_1.to_str }.freeze)
      end

      # Position-independent: the same bytes in the same file, wherever they sit.
      def content_key = key(CONTENT_SCHEME, path_frame, body)

      # Qualified by the OLD-side span, which the author's own edits do not move.
      def span_key = key(SPAN_SCHEME, path_frame, old_span_frame, body)

      # The tie-breaker of last resort. Its frame is `o,c n,c`, which no
      # old-side frame can spell, so the two cannot collide.
      def full_span_key = key(SPAN_SCHEME, path_frame, full_span_frame, body)

      private

      # Length-framed so that no shift of the path/body boundary can collide,
      # even for a path carrying the separator itself.
      def path_frame = "#{path.bytesize}\n#{path}\n"

      def old_span_frame = "#{old_start},#{old_count}\n"

      def full_span_frame = "#{old_start},#{old_count} #{new_start},#{new_count}\n"

      # `.b` per LINE, not once over the join: two lines of one diff can carry
      # different encodings, and joining those raises instead of hashing.
      def body = lines.map(&:b).join("\n")

      # The scheme is HASHED, not merely prefixed. As a bare prefix it leaves a
      # content digest forgeable into a span digest by a body whose first line
      # mimics a span frame. No key is journaled yet, so this costs nothing
      # today and would be a migration once T8 and T13 write them down.
      def key(scheme, *parts)
        -"#{scheme}:#{Ext.blake3_hex(["#{scheme}\n", *parts].map(&:b).join)}"
      end
    end
  end
end
