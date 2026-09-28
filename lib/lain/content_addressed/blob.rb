# frozen_string_literal: true

module Lain
  module ContentAddressed
    # Git's object framing -- a tag word, the byte length, a NUL -- over the RAW
    # bytes, blake3 over the whole of it. Deliberately not {Canonical}, which
    # pins UTF-8 and would refuse arbitrary file content, and the header is what
    # keeps byte content that happens to spell a canonical dump from colliding
    # with one.
    #
    # The tag IS the keyspace, which is why it is required and never defaulted:
    # two subsystems sharing one make a digest over the same bytes mean two
    # things at once, and nothing anywhere would say so out loud.
    # {Workspace::Snapshot::Blob} holds `blob` and every snapshot ever recorded
    # rests on it; an attachment holds its own.
    #
    # Constructible only on the main Ractor, because `Ext.blake3_hex` is not
    # ractor-safe, while the value it makes is shareable -- the trade
    # {Sensitivity::Regions::Region} and Hunk make too, and what lets a caller
    # cache by digest in a loop.
    class Blob
      include ContentAddressed

      attr_reader :bytes, :digest, :tag

      # @param bytes [String] in whatever encoding the caller read them under
      # @param tag [String] the keyspace this address belongs to
      # @raise [ArgumentError] on a tag that cannot frame
      def initialize(bytes:, tag:)
        @tag = framing(tag)
        # `String#b` copies into BINARY, so identical bytes address identically
        # whatever encoding the caller read under. The header is `.b`'d too:
        # interpolating binary bytes into a UTF-8 literal raises
        # Encoding::CompatibilityError, concatenation does not.
        @bytes = bytes.b.freeze
        @digest = -"#{Canonical::DIGEST_ALGORITHM}:#{Ext.blake3_hex(header + @bytes)}"
        freeze
      end

      def to_s = "#<#{self.class} #{bytes.bytesize}B #{digest[0, 19]}...>"
      alias inspect to_s

      private

      def header = "#{@tag} #{@bytes.bytesize}\0".b

      # The NUL is what ends the header, so a tag carrying one lets two
      # different (tag, bytes) pairs frame to one byte string -- the collision
      # the header exists to make impossible. An empty tag separates nothing.
      # Narrower than it looks: a tag that is not a String at all reaches
      # `NoMethodError` from `empty?` rather than this sentence, which is loud
      # enough, and narrowing it would mean ruling on whether a Symbol is a tag
      # when every caller passes a String constant.
      def framing(tag)
        raise ArgumentError, "a blob tag must be non-empty and carry no NUL: #{tag.inspect}" if
          tag.empty? || tag.include?("\0")

        -tag
      end
    end
  end
end
