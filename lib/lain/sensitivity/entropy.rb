# frozen_string_literal: true

module Lain
  class Sensitivity
    # Whether a token is random enough to be a secret, judged by Shannon
    # entropy plus the shapes that are varied but wholly predictable.
    module Entropy
      # Hex maxes out at 4.0 bits/char, so it needs its own floor; a random
      # 32-char hex key sits at ~3.9 and a sha1 at ~3.74, and catching the second
      # to keep the first is the trade this asymmetry is worth. Base64 runs need
      # the higher floor because paths and URLs are base64url-legal and sit at
      # 4.0-4.2 -- at 4.0 the detector reported 41 `lib/` file paths as secrets.
      #
      # `HEX_LENGTH` binds in BOTH directions, and a spec covers each.
      # `Regions`' entropy scan is `TOKEN`-filtered at `{20,}`, so on that path a
      # shorter run never arrives and the constant is inert; an assignment's
      # VALUE reaches the same predicate with no pre-filter, so at 10 a line like
      # `blob = 3f5a9c2e1d7b` reports a region and at 20 it does not.
      HEX_ENTROPY = 3.0
      HEX_LENGTH = 20
      BASE64_ENTROPY = 4.2
      BASE64_LENGTH = 24

      # Entropy cannot tell a path from a secret: slash-joined words score 4.21
      # to 4.40 bits per character, an AWS secret key 4.66. Each segment can
      # be judged alone, though: a word keeps one case shape and is short or
      # repetitive, while a generated key mixes case or is a long
      # high-entropy run in one case. A secret split into short lowercase
      # segments is given up for that.
      WORD_SEGMENT = /\A(?:[a-z0-9._-]+|[A-Z0-9_]+|[A-Z][a-z]+)\z/
      # An alphabet literal (base64's, a charset table) is maximally varied and
      # wholly predictable; no generator emits 16 consecutive code points. The
      # runs must cover most of the token, or a key glued onto one goes too.
      ALPHABET_RUN = 16
      HEX = /\A[0-9a-fA-F]+\z/
      BASE64 = %r{\A[A-Za-z0-9+/=_-]+\z}

      class << self
        def high?(token)
          return token.length >= HEX_LENGTH && shannon(token) >= HEX_ENTROPY if token.match?(HEX)

          token.length >= BASE64_LENGTH && token.match?(BASE64) && shannon(token) >= BASE64_ENTROPY
        end

        def predictable?(token) = slash_joined_words?(token) || alphabet_run?(token)

        # Bits per character. `each_char` over BINARY bytes is deliberate: the
        # measure is over the symbols as they were written, and re-decoding to
        # find codepoints is the thing that raises.
        def shannon(token)
          length = token.length.to_f
          -token.each_char.tally.each_value.sum { |count| (count / length) * Math.log2(count / length) }
        end

        private

        def slash_joined_words?(token)
          segments = token.split("/").reject(&:empty?)

          segments.size >= 2 && segments.all? { _1.match?(WORD_SEGMENT) && !high?(_1) }
        end

        def alphabet_run?(token)
          covered = token.each_byte.chunk_while { |before, after| after == before + 1 }
                         .sum { _1.size >= ALPHABET_RUN ? _1.size : 0 }

          covered * 2 > token.bytesize
        end
      end
    end
  end
end
