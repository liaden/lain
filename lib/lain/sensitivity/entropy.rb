# frozen_string_literal: true

module Lain
  class Sensitivity
    # Whether a token is random enough to be a secret, judged by Shannon
    # entropy plus the shapes that are varied but wholly predictable.
    module Entropy
      # Hex maxes out at 4.0 bits/char, so it needs its own floor; a random
      # 32-char hex key sits at ~3.9 and a sha1 at ~3.74, so the floor cannot
      # part them and {DIGEST_HEX} does it by width and case instead. Base64 runs need
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
      # A model id's segment (`SmolLM2-360M-Instruct-GGUF`) joins camel-case
      # pieces with separators. Every word is a capital then 3 or more letters,
      # because random base62 breaks into 2-letter capital-lowercase pairs that
      # fit a looser word; a segment still needs 1 such word, not only acronyms.
      REAL_WORD = /[A-Z][a-z]{2,}/
      CAMEL_PIECE = /\A(?:[A-Z][a-z]{2,}|[A-Z]{2,}|\d+[A-Z]?)+\z/
      # An alphabet literal (base64's, a charset table) is maximally varied and
      # wholly predictable; no generator emits 16 consecutive code points. The
      # runs must cover most of the token, or a key glued onto one goes too.
      ALPHABET_RUN = 16
      HEX = /\A[0-9a-fA-F]+\z/
      # md5, sha1, sha256 and sha512 widths, printed lowercase by every tool
      # that prints one. The trade: a generated hex key at those widths with no
      # hinting name beside it is let through, so a digest list reads whole.
      DIGEST_HEX = /\A(?:[0-9a-f]{32}|[0-9a-f]{40}|[0-9a-f]{64}|[0-9a-f]{128})\z/
      BASE64 = %r{\A[A-Za-z0-9+/=_-]+\z}

      # The relaxed bar for a value passed under a name that hints at a
      # connection string, measured on a 65-value labelled corpus: 16 chars at
      # 3.5 bits found the most secrets for the fewest harmless values. The
      # three character classes are what keep a UUID or a long identifier out.
      HINTED_LENGTH = 16
      HINTED_ENTROPY = 3.5
      HINTED_CLASSES = [/[a-z]/, /[A-Z]/, /[0-9]/].freeze
      # Hex has one letter case and tops out at 4.0 bits, so a hex key cannot
      # pass the class rule and gets its own branch. At 3.0 bits it took the
      # corpus from 27 secrets to 28 with no new harmless value. The letter
      # rule keeps a 16-digit number or a 17-digit timestamp out.
      HINTED_HEX = /\A(?=.*[a-f])[0-9a-f]{#{HINTED_LENGTH},}\z/i
      HINTED_HEX_ENTROPY = 3.0

      class << self
        def high?(token)
          return token.length >= HEX_LENGTH && shannon(token) >= HEX_ENTROPY if token.match?(HEX)

          token.length >= BASE64_LENGTH && token.match?(BASE64) && shannon(token) >= BASE64_ENTROPY &&
            !slash_joined_words?(token)
        end

        # @param token [String]
        # @param hinted [Boolean] true when a name beside the token hints at a
        #   secret, which is the evidence a digest-width run otherwise lacks
        def predictable?(token, hinted: false)
          slash_joined_words?(token) || alphabet_run?(token) || (!hinted && token.match?(DIGEST_HEX))
        end

        def hinted?(token)
          return false if token.include?("/") || predictable?(token, hinted: true)
          return shannon(token) >= HINTED_HEX_ENTROPY if token.match?(HINTED_HEX)

          token.length >= HINTED_LENGTH && HINTED_CLASSES.all? { token.match?(_1) } &&
            shannon(token) >= HINTED_ENTROPY
        end

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

          segments.size >= 2 && segments.all? { word_segment?(_1) }
        end

        def word_segment?(segment)
          (segment.match?(WORD_SEGMENT) && !high?(segment)) || camel_name?(segment)
        end

        def camel_name?(segment)
          pieces = segment.split(/[-_.]/).reject(&:empty?)

          segment.match?(REAL_WORD) && pieces.all? { _1.match?(CAMEL_PIECE) }
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
