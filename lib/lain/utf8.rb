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

    # @param bytes [#to_s] any encoding, invalid sequences included
    # @param replacement [String, nil] what an invalid sequence becomes; nil is U+FFFD
    # @return [String] a new, valid UTF-8 String
    def legible(bytes, replacement = nil)
      bytes.to_s.dup.force_encoding(Encoding::UTF_8).scrub(replacement)
    end
  end
end
