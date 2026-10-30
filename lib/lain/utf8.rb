# frozen_string_literal: true

module Lain
  # Bytes a child process, a file or the wire was free to make invalid, made
  # readable: re-tagged UTF-8 and scrubbed, never encoded. `encode` is a no-op
  # on a String already tagged UTF-8, so invalid bytes sail through it; `scrub`
  # replaces exactly the sequences that are not valid UTF-8 and leaves legible
  # content untouched. Lossy by design, so it is for a surface a human reads,
  # never for bytes that are hashed or diffed.
  module Utf8
    module_function

    # The bytes must decode as UTF-8 whatever the tag says: a binary-tagged
    # String is always `valid_encoding?`, so the label alone proves nothing.
    #
    # @param text [String]
    # @return [Boolean]
    def bytes?(text)
      return text.valid_encoding? if text.encoding == Encoding::UTF_8

      text.ascii_only? || text.dup.force_encoding(Encoding::UTF_8).valid_encoding?
    end

    # @param bytes [#to_s] any encoding, invalid sequences included
    # @param replacement [String, nil] what an invalid sequence becomes; nil is U+FFFD
    # @return [String] a new, valid UTF-8 String
    def legible(bytes, replacement = nil)
      bytes.to_s.dup.force_encoding(Encoding::UTF_8).scrub(replacement)
    end

    # The controls that move a cursor or reorder text. Not all of `\p{Cf}`: U+200D joins an emoji.
    MOVING = /[\p{Cc}\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]/

    # @param text [#to_s]
    # @param keep [String] characters left as they are, such as a newline
    # @param also [Regexp] further characters to write out, beyond {MOVING}
    # @return [String] scrubbed, every {MOVING} or `also` character outside `keep` written out as its escape
    def escaped(text, keep: "", also: MOVING)
      legible(text).gsub(Regexp.union(MOVING, also)) { |char| keep.include?(char) ? char : char.dump[1..-2] }
    end
  end
end
