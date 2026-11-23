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
      # A name with a build hash after a dash, as cargo names an artifact
      # (`word_count-46e9759e7fd1a230`). The hex is capped at a build hash's
      # width so a longer run behind a word is judged as a word segment.
      WORD_HEX = /\A[a-z][a-z0-9_]*(?:-[a-z][a-z0-9_]*)*-[0-9a-f]{8,16}\z/
      # `Dir.mktmpdir` names a directory for the date, the pid and at most 7 random base-36
      # characters, too few to hold a secret. The prefix is the caller's, so it is judged as words.
      TMPNAME = /\A(?<prefix>.*?)(?:19|20)\d{6}-\d{1,10}-[0-9a-z]{1,7}\z/
      # Stores that name a directory by its content hash, each as the run of
      # segments that holds the hash. A hash segment is let through only in its
      # place in a run, so the same hex anywhere else in a URL is still a key.
      # A `name` group is the part a person chose, so it is judged as words.
      # The bare huggingface run is for a token that starts inside a repo name
      # cut at its dot (`models--Qwen--Qwen2.5-7B-Instruct`).
      CONTENT_ADDRESSED = [
        [/\Anix\z/, /\Astore\z/, /\A[0-9a-df-np-sv-z]{32}-(?<name>.+)\z/].freeze,
        [/\Agit\z/, /\Aobjects\z/, /\A[0-9a-f]{2}\z/, /\A(?:[0-9a-f]{38}|[0-9a-f]{62})\z/].freeze,
        [/\Aoverlay2\z/, /\A[0-9a-f]{64}\z/].freeze,
        [/\A(?:models|datasets|spaces)--(?<name>[\w-]+)\z/, /\Asnapshots\z/, /\A[0-9a-f]{40}\z/].freeze,
        [/\Asnapshots\z/, /\A[0-9a-f]{40}\z/].freeze
      ].freeze
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
          return token.length >= HEX_LENGTH && Ext::Entropy.shannon(token) >= HEX_ENTROPY if token.match?(HEX)

          token.length >= BASE64_LENGTH && token.match?(BASE64) && Ext::Entropy.shannon(token) >= BASE64_ENTROPY &&
            !predictable_path?(token)
        end

        # @param token [String]
        # @param hinted [Boolean] true when a name beside the token hints at a
        #   secret, which is the evidence a digest-width run otherwise lacks
        def predictable?(token, hinted: false)
          predictable_path?(token) || Ext::Entropy.alphabet_run?(token) || (!hinted && token.match?(DIGEST_HEX))
        end

        def hinted?(token)
          return false if token.include?("/") || predictable?(token, hinted: true)
          return Ext::Entropy.shannon(token) >= HINTED_HEX_ENTROPY if token.match?(HINTED_HEX)

          token.length >= HINTED_LENGTH && HINTED_CLASSES.all? { token.match?(_1) } &&
            Ext::Entropy.shannon(token) >= HINTED_ENTROPY
        end

        private

        def predictable_path?(token)
          segments = token.split("/").reject(&:empty?)

          segments.size >= 2 &&
            segments.each_index.all? { word_segment?(segments[_1]) || addressed_at?(segments, _1) }
        end

        def addressed_at?(segments, index)
          CONTENT_ADDRESSED.any? do |layout|
            layout.each_with_index.any? do |shape, offset|
              start = index - offset
              segments[index].match?(shape) && start >= 0 && start + layout.size <= segments.size &&
                addressed_run?(segments, start, layout)
            end
          end
        end

        def addressed_run?(segments, start, layout)
          layout.each_index.all? { addressed?(segments[start + _1], layout[_1]) }
        end

        def addressed?(segment, shape)
          return segment.match?(shape) if shape.names.empty?

          match = shape.match(segment)
          !match.nil? && match[:name].split("--").reject(&:empty?).all? { word_segment?(_1) }
        end

        def word_segment?(segment)
          (segment.match?(WORD_SEGMENT) && !high?(segment)) || segment.match?(WORD_HEX) || camel_name?(segment) ||
            tmpname?(segment)
        end

        def tmpname?(segment)
          prefix = TMPNAME.match(segment)&.[](:prefix)
          !prefix.nil? && (prefix.empty? || word_segment?(prefix))
        end

        def camel_name?(segment)
          pieces = segment.split(/[-_.]/).reject(&:empty?)

          segment.match?(REAL_WORD) && pieces.all? { _1.match?(CAMEL_PIECE) }
        end
      end
    end
  end
end
