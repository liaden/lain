# frozen_string_literal: true

module Lain
  class Sensitivity
    # The sensitive spans of a file's bytes, each addressed by its own content.
    # Two detectors run over the same bytes: the credential shapes from
    # {CredentialPatterns.for} `(:content)`, and a Shannon-entropy run detector
    # for tokens no issuer prefix names. Entropy is TRIAGE, not a verdict -- it
    # routes a file to review, and a false positive costs one release decision
    # because {Sensitivity::Ledger} caches by digest.
    #
    # The gate's measured false-positive rates, the residual imprecision, the
    # recall list, the JWT-is-three-regions consequence and the ~0.27ms/KB linear
    # cost are all in ARCHITECTURE.md's "The secret boundary". Two things a
    # reader editing this file needs in front of them:
    #
    # * A region is its VALUE, not its whole assignment. `API_KEY=sk-...` yields
    #   a region covering `sk-...` alone, so a masked `.env` stays legible as a
    #   `.env` and partial approval falls out of keeping the names. The
    #   consequence is accepted rather than worked around: two identical values
    #   in one file share a digest, so one release decision covers both --
    #   identical bytes are the same secret, and the ledger keys by path, so
    #   nothing leaks between files.
    # * Not `Canonical.digest`. A region is already bytes, and
    #   `review/hunk.rb:10-14` settles the identical question: a JSON-native
    #   canonicalization normalizes away exactly the differences an identity key
    #   exists to keep, and it raises outright on bytes that are not valid UTF-8
    #   -- which file content routinely is not.
    module Regions
      # What a withheld region looks like wherever one is rendered. It lives
      # HERE, beside the detector and not in either arm that renders one,
      # because two arms mask now -- a `read_file` result on its way out of the
      # tool phase ({Middleware::RedactSecretReads}) and a survey's projection of
      # a file it may list ({Survey::Projection}) -- and a human has to
      # recognise the same thing in both.
      #
      # The `%d` is an ORDINAL, counting masked regions in reading order, and
      # never the byte length withheld: a length discloses how long the secret
      # is, which is a fact about the secret. The ordinal discloses only how many
      # there are, which the release prompt already tells the human.
      PLACEHOLDER = "<redacted:%d>"

      # A region no pattern named. Journaled as-is, so triage stays legible as
      # triage rather than reading like a matched credential.
      ENTROPY_REASON = "high-entropy token"

      # Hex maxes out at 4.0 bits/char, so it needs its own floor; a random
      # 32-char hex key sits at ~3.9 and a sha1 at ~3.74, and catching the second
      # to keep the first is the trade this asymmetry is worth. Base64 runs need
      # the higher floor because paths and URLs are base64url-legal and sit at
      # 4.0-4.2 -- at 4.0 the detector reported 41 `lib/` file paths as secrets.
      #
      # `HEX_LENGTH` binds in BOTH directions, and a spec covers each.
      # `entropy_candidates` is `TOKEN`-filtered at `{20,}`, so on that path a
      # shorter run never arrives and the constant is inert; an assignment's
      # VALUE reaches the same predicate through `qualifies? -> secret_shaped?`
      # with no pre-filter, so at 10 a line like `blob = 3f5a9c2e1d7b` reports a
      # region and at 20 it does not.
      HEX_ENTROPY = 3.0
      HEX_LENGTH = 20
      BASE64_ENTROPY = 4.2
      BASE64_LENGTH = 24

      NAME_HINT = /pass|secret|token|api[_-]?key|credential|auth|private|signature|session/i

      # A name hint is a weak signal and needs the value to be worth showing a
      # human. Without this floor the name arm reported `)`, `,`, `=`, `>` and
      # bare integers -- 24 pure-punctuation regions across `lib/` alone, each of
      # which becomes a prompt reading "release the value `)`?".
      #
      # SIX, not eight. The junk this exists to kill is 1-2 characters of
      # punctuation and 4-character integers, so six clears all of it -- while
      # eight would discard `DATABASE_PASSWORD=hunter2`, which is the exact case
      # the name-substring gate is argued from. A floor that deletes the recall
      # its own gate was designed to buy is set too high, whatever round number
      # it matches.
      SUBSTANCE_LENGTH = 6
      ALPHANUMERIC_RUN = /[A-Za-z0-9]/

      # `yaml assignment` needs only a colon and a space, so its name arm admits
      # any `word: text` line in prose or code -- it is the shape that floods.
      # Value-shape only for it, and nothing real is lost: a genuinely named
      # credential like `password: hunter2pass` is matched by `credential
      # assignment` directly, and a real `secrets.yml` is gated by PATH before
      # its content is ever read.
      VALUE_GATED_ONLY = ["yaml assignment"].freeze
      # `=` is base64 PADDING and so may only trail. Admitting it mid-token let
      # one run swallow `API_KEY=` along with the secret, which then merged the
      # name back into the region the value-only rule exists to exclude.
      TOKEN = %r{[A-Za-z0-9+/_-]{20,}={0,2}}
      HEX = /\A[0-9a-fA-F]+\z/
      BASE64 = %r{\A[A-Za-z0-9+/=_-]+\z}
      ASSIGNMENT = /\A[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_-]*)[ \t]*[:=][ \t]*(\S.*)\z/m
      # `.b` returns a NEW, MUTABLE String, so `frozen_string_literal` does not
      # reach this one and it has to be frozen by hand.
      BOM = "\xEF\xBB\xBF".b.freeze

      # Issuer-fixed shapes are whole-match secrets; the assignment shapes are
      # gated and contribute only their value. Order is the table's own, so a
      # span both shapes reach is named by the one that says more.
      PATTERNS = CredentialPatterns.for(:content).keys.each_with_index.to_h.freeze

      class << self
        # A BOM defeats every line-anchored shape on line 1 -- `^` anchors before
        # it and a BOM is not `[ \t]` -- so it is skipped for the scan and added
        # back to every offset, which keeps offsets indexing the bytes the caller
        # handed over rather than the ones that were scanned.
        #
        # @param content [String] file bytes in any encoding; re-tagged BINARY
        #   here rather than by the caller, because the credential table
        #   deliberately does not normalize and this is the consumer that needs
        #   it. UTF-16 and invalid UTF-8 are safe as a result.
        # @return [Array<Region>] frozen, ascending by offset, no two overlapping
        def detect(content)
          bytes = content.b
          skip = bytes.start_with?(BOM) ? BOM.bytesize : 0
          scanned = skip.zero? ? bytes : bytes.byteslice(skip..)

          # `:rank` makes the sort key TOTAL. No output depends on it -- equal
          # starts always overlap, so they merge, and `coalesced` picks the name
          # by rank anyway -- but `sort_by` is not stable, and without it the
          # fold's intermediate order is arbitrary. Deliberately unpinnable: no
          # mutant can kill it, which is the honest reason there is no spec.
          merge(candidates(scanned).sort_by { [_1[:start], _1[:rank]] }, bytes, skip)
        end

        private

        def merge(sorted, bytes, skip) = coalesce(sorted).map { region_at(_1, bytes, skip) }.freeze

        # One secret is one region however many detectors reach it:
        # `API_KEY=sk-` is a dotenv assignment, an issuer prefix, a credential
        # assignment and a high-entropy run, and reporting four would ask the
        # human four times about one thing.
        def coalesce(sorted)
          sorted.each_with_object([]) do |candidate, kept|
            previous = kept.last
            if previous && candidate[:start] < previous[:finish]
              kept[-1] = coalesced(previous, candidate)
            else
              kept << candidate
            end
          end
        end

        # The merged span takes the name of the higher-precedence shape, which is
        # not always the one that started first.
        def coalesced(previous, candidate)
          [previous, candidate].min_by { _1[:rank] }
                               .merge(start: previous[:start],
                                      finish: [previous[:finish], candidate[:finish]].max)
        end

        def region_at(candidate, bytes, skip)
          start = candidate[:start] + skip
          Region.new(start:, bytes: bytes.byteslice(start, candidate[:finish] - candidate[:start]),
                     reason: candidate[:reason], detector: candidate[:detector])
        end

        def candidates(scanned) = pattern_candidates(scanned) + entropy_candidates(scanned)

        def pattern_candidates(scanned)
          CredentialPatterns.for(:content).flat_map do |name, shape|
            matches(scanned, shape).filter_map { |match| pattern_candidate(name, match) }
          end
        end

        # `String#to_enum(:scan)` is what exposes `Regexp.last_match` per
        # iteration; `scan` alone yields text without offsets.
        def matches(scanned, shape) = scanned.to_enum(:scan, shape).map { Regexp.last_match }

        def pattern_candidate(name, match)
          assignment = ASSIGNMENT.match(match[0])
          return span(match.begin(0), match[0], name, :pattern) unless assignment

          return nil unless qualifies?(name, assignment[1], assignment[2])

          value_span(match, assignment, name)
        end

        # The emitted span is the UNQUOTED value. Quotes are the file's syntax,
        # not the secret: masking a span that carries its own delimiters would
        # destroy the quoting that made the file parse, and a quoted and an
        # unquoted copy of one secret would address differently.
        def value_span(match, assignment, name)
          value = assignment[2]
          emitted = unquote(value)
          within = match[0].byteindex(value, assignment[1].bytesize) + value.byteindex(emitted)

          span(match.begin(0) + within, emitted, name, :pattern)
        end

        def qualifies?(name, key, value)
          return secret_shaped?(value) if VALUE_GATED_ONLY.include?(name)

          (key.match?(NAME_HINT) && substantial?(value)) || secret_shaped?(value)
        end

        def substantial?(value)
          token = unquote(value)

          token.bytesize >= SUBSTANCE_LENGTH && token.match?(ALPHANUMERIC_RUN)
        end

        def entropy_candidates(scanned)
          matches(scanned, TOKEN).select { secret_shaped?(_1[0]) }
                                 .map { span(_1.begin(0), _1[0], ENTROPY_REASON, :entropy) }
        end

        def span(start, text, reason, detector)
          { start:, finish: start + text.bytesize, reason:, detector:,
            rank: detector == :entropy ? PATTERNS.size : PATTERNS.fetch(reason) }
        end

        def secret_shaped?(value)
          token = unquote(value)

          issuer_fixed?(token) || high_entropy?(token)
        end

        # Quotes belong to the file's syntax, not to the secret. Left on, a short
        # dull value clears the length floor on its own delimiters.
        def unquote(value)
          value.strip.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
        end

        def issuer_fixed?(token) = CredentialPatterns.for(:write).any? { |_, shape| token.match?(shape) }

        def high_entropy?(token)
          return token.length >= HEX_LENGTH && shannon(token) >= HEX_ENTROPY if token.match?(HEX)

          token.length >= BASE64_LENGTH && token.match?(BASE64) && shannon(token) >= BASE64_ENTROPY
        end

        # Bits per character. `each_char` over BINARY bytes is deliberate: the
        # measure is over the symbols as they were written, and re-decoding to
        # find codepoints is the thing that raises.
        def shannon(token)
          length = token.length.to_f
          -token.each_char.tally.each_value.sum { |count| (count / length) * Math.log2(count / length) }
        end
      end
      Region = Data.define(:start, :bytes, :reason, :detector, :digest)

      # One sensitive span, and the digest that is its identity.
      #
      # The digest is of the region's OWN BYTES and never of its offset: a line
      # inserted above a secret must not invalidate it, or a region's address
      # would be whole-file behavior wearing a region's name.
      #
      # The framing is git's -- a type word, the byte length, a NUL -- borrowed
      # from `workspace/snapshot.rb:75`, with the type word deliberately changed
      # to `sensitive-region-v1`. That file's own comment says the header exists
      # TO domain-separate; reusing `blob` would make a region's digest identical
      # to a snapshot blob's for the same bytes, silently merging two
      # content-addressing keyspaces. The house precedent is Hunk's
      # `hunk-content-v1`/`hunk-span-v1`.
      #
      # A Region is shareable, but it can only be CONSTRUCTED on the main
      # Ractor, because `Ext.blake3_hex` is not ractor-safe -- the same recorded
      # gap Hunk, Fuzzy and Bm25 carry. Digesting eagerly moves that constraint
      # from every read of the digest to the one construction, which is what lets
      # a caller cache by digest in a loop; `Snapshot::Blob` makes the same trade.
      class Region
        SCHEME = "sensitive-region-v1"

        DETECTORS = %i[pattern entropy].freeze

        # @param bytes [String] the region's own bytes, in any encoding
        # @return [String] `blake3:<hex>` over the length-framed, scheme-tagged
        #   bytes
        def self.address(bytes)
          -"#{Canonical::DIGEST_ALGORITHM}:#{Ext.blake3_hex("#{SCHEME} #{bytes.bytesize}\0".b + bytes)}"
        end

        def initialize(start:, bytes:, reason:, detector:)
          raise ArgumentError, "unknown detector #{detector.inspect}: expected #{DETECTORS.inspect}" \
            unless DETECTORS.include?(detector)

          content = -bytes.b
          super(start: Integer(start), bytes: content, reason: -reason.to_str, detector:,
                digest: Region.address(content))
        end

        def length = bytes.bytesize

        # Triage, not a match. The Journal and the release prompt both need to
        # say which one this was without comparing a reason string.
        def entropy? = detector == :entropy

        # Never the bytes -- but note what it DOES render: offset, length and
        # the detector's reason. That is safe in a backtrace and unsafe in a
        # prompt, so no human-facing string may interpolate a Region.
        # {Approval::Queue::Outstanding#preamble} says WHICH file and HOW MANY
        # for exactly that reason, and a future `"#{outstanding}"` written for
        # convenience would undo it by disclosing where in the file each secret
        # sits and how long it is.
        def to_s = "#<Lain::Sensitivity::Regions::Region #{start}+#{length} #{reason}>"
        alias inspect to_s
      end
    end
  end
end
