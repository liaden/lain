# frozen_string_literal: true

module Lain
  module Survey
    Unit = Data.define(:path, :label, :start_line, :lines)

    # One reviewable piece of a file read AS IT STANDS -- a paragraph run, a
    # markdown section, a definition and the lines around it -- and the key that
    # carries its reviewed state from one survey of that file to the next.
    #
    # A unit is what a hunk is to a diff, minus the diff: there is no old side,
    # no origin marker and no `@@` header, so it holds only the path it came
    # from, where it starts, its lines, and a LABEL naming the structure it was
    # found inside. The label is derived presentation and is deliberately out of
    # the key -- a chunker that starts naming sections better must not clear
    # every mark in the corpus.
    #
    # Lines are TERMINATOR-FREE, split by {.lines_of}, because the survey's
    # consumer turns a unit into a `Hunk` whose lines carry a `+` origin marker;
    # a line holding its own newline could not wear one.
    #
    # == Why the scheme is its own
    #
    # `unit-content-v1`, not `hunk-content-v1`. A one-unit surveyed file and the
    # same file newly ADDED in a branch diff hash byte-identically under the
    # hunk scheme -- same path frame, same body once the all-`+` markers are
    # stripped -- so sharing it would let a corpus mark satisfy a changeset
    # hunk. No key is journaled yet, so minting one costs a constant now and a
    # migration later.
    #
    # Keys route through {Review::Keying} rather than repeating {Hunk#key}'s
    # framing. Hunk is exempt because rewriting it would move every mark already
    # stored; a scheme minted today carries no such debt, so it takes the
    # length-framed, uniquely decodable layout that module exists to defend.
    #
    # Keys are derivable on the MAIN Ractor only: a Unit is shareable, but
    # `Ext.blake3_hex` is not ractor-safe -- the same recorded gap {Hunk} carries.
    class Unit
      CONTENT_SCHEME = "unit-content-v1"
      SPAN_SCHEME = "unit-span-v1"

      # One buffer line per line the file holds. A trailing newline TERMINATES
      # the last line rather than starting an empty one, which is how an editor
      # reads the same file -- but a file that is ONLY a newline still holds one
      # line, an empty one. `delete_suffix("\n").split` gets that last case
      # wrong (`"".split` is `[]`, not `[""]`) and the miss is invisible:
      # reconstruction restores the trailing newline from the source, so a whole
      # unshown line still compares byte-identical.
      #
      # Splitting is done on BYTES and the encoding restored per line, for the
      # reason {Review::Hunk#body} gives: `String#split` validates, so one
      # latin-1 byte in a UTF-8-tagged file raised `ArgumentError: invalid byte
      # sequence` naming neither the file nor the offset. A newline is one ASCII
      # byte in every encoding here, so splitting on bytes cannot cut a
      # character in half, and each piece carries exactly the bytes -- and the
      # encoding tag -- the file had.
      #
      # Never `chomp("\n")`: chomp treats that argument as the RECORD separator
      # and strips a trailing "\r\n" whole, so a CRLF file would lose the one
      # carriage return this method promises not to touch -- and only that one,
      # which is a last line that differs from every line above it. That is
      # `Changeset#lines`' rule, kept.
      #
      # @param bytes [String] the whole file
      # @return [Array<String>] frozen lines in a frozen array, terminator-free
      def self.lines_of(bytes)
        raw = bytes.b
        lines = raw.split("\n", -1)
        lines.pop if raw.end_with?("\n")
        encoding = bytes.encoding
        lines.map { |line| -line.force_encoding(encoding) }.freeze
      end

      # The review keys for a whole chunking, in the order given. The batch is a
      # precondition, not a convenience, for the reason {Hunk.keys} records: a
      # unit cannot tell on its own that it is duplicated, and byte-identical
      # units are ordinary in prose -- a repeated licence header, a run of
      # separators -- so keying one at a time hands two of them the same key.
      #
      # Two levels suffice where a hunk needs three, and that is provable rather
      # than lucky: the coverage contract gives every unit of a file a distinct
      # start line, and the span key frames the path, so no two units in any
      # chunking can share a span key.
      #
      # @param units [Array<Unit>]
      # @return [Array<String>] frozen, one key per unit, all distinct
      def self.keys(units)
        content = units.map(&:content_key)
        duplicated = content.tally
        units.zip(content).map { |unit, key| duplicated[key] > 1 ? unit.span_key : key }.freeze
      end

      # `to_str` rather than `to_s`, to match the loudness of the `Integer()`
      # beside it: a nil path must raise here, not address as the empty string.
      def initialize(path:, start_line:, lines:, label: "")
        super(path: -path.to_str, label: -label.to_str, start_line: Integer(start_line),
              lines: lines.map { -_1.to_str }.freeze)
      end

      # Position-independent: the same bytes in the same file, wherever they sit.
      def content_key = Review::Keying.digest(CONTENT_SCHEME, [path, *lines])

      # Qualified by where the unit sits, for the duplicate case only.
      def span_key = Review::Keying.digest(SPAN_SCHEME, [path, start_line, lines.size, *lines])

      def end_line = start_line + lines.size - 1
    end
  end
end
