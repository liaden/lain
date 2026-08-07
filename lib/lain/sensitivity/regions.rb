# frozen_string_literal: true

module Lain
  class Sensitivity
    # The sensitive spans of a file's bytes, each addressed by its own content.
    #
    # Two detectors run over the same bytes: the credential shapes from
    # {CredentialPatterns.for} `(:content)`, and a Shannon-entropy run detector for
    # tokens no issuer prefix names. Entropy is TRIAGE, not a verdict -- it routes
    # a file to review, and a false positive costs one release decision because
    # {Sensitivity::Ledger} caches by digest.
    #
    # == A region is its VALUE, not its whole assignment
    #
    # `API_KEY=sk-...` yields a region covering `sk-...` alone. The masking side
    # renders an unreleased region as a placeholder, so a region spanning the name
    # too would erase the key names that make a masked `.env` still legible as a
    # `.env` -- and partial approval falls out of keeping them. The consequence is
    # accepted rather than worked around: two identical values in one file share a
    # digest, so one release decision covers both. Identical bytes are the same
    # secret, and the ledger keys by path, so nothing leaks between files.
    #
    # == Why not `Canonical.digest`
    #
    # A region is already bytes. `review/hunk.rb:10-14` settles the identical
    # question: a JSON-native canonicalization normalizes away exactly the
    # differences an identity key exists to keep, and it raises outright on bytes
    # that are not valid UTF-8 -- which file content routinely is not.
    #
    # == The gate, and why the card's original rate was unusable
    #
    # An assignment yields a region only when its NAME hints at a credential over
    # a value with SUBSTANCE, or its VALUE is secret-SHAPED. Measured over this
    # repo before the gate -- `**/*.md` less `references/repos/` and `.claude/`,
    # plus `lib/**/*.rb` and `spec/**/*.rb` -- {CredentialPatterns.for} `(:content)`
    # alone matched **70.9%, 86.0% and 95.4%** of files. The markdown figure is
    # 95 of 134, which is the number that table's own docstring records.
    #
    # `dotenv assignment` is the reason for the source-code rates, and it is not a
    # defect in that shape: `^ident = value` IS Ruby assignment syntax, so a
    # name-agnostic assignment shape matches source code by construction.
    #
    # The name is matched as a SUBSTRING rather than on a word boundary, which is
    # the same argument {CredentialPatterns::ASSIGNMENTS} makes for being
    # name-agnostic at all: `DATABASE_PASSWORD` has no word boundary before
    # `PASSWORD`. A value-shape test alone would not do, because a named
    # passphrase is low-entropy -- exactly the secret a shape test structurally
    # cannot see.
    #
    # == Measured residual imprecision, not estimated
    #
    # Gate, substance floor and thresholds together, over the same three globs:
    #
    #   corpus         files with a region    regions   pattern / entropy
    #   markdown       28 of 134 (20.9%)           57       7 /  50
    #   lib/**/*.rb    36 of 602 ( 6.0%)           53      52 /   1
    #   spec/**/*.rb   63 of 581 (10.8%)          262     218 /  44
    #
    # The floor costs little across its plausible range, which is why it sits at
    # the recall-preserving end of it. At 8 rather than 6: markdown 55 regions,
    # `lib/` 49, `spec/` 232 -- so eight buys back 2, 4 and 20 regions of noise
    # (mostly 6-7 byte code fragments like `test")`) and pays for them with
    # `hunter2`.
    #
    # This file and its spec are IN that corpus, so the sample JWT header below
    # and the spec's hex fixtures are among those counts. Worth stating, because
    # measuring a change to this detector against a corpus containing the
    # detector is how a review of this card produced a false finding: an edit that
    # shortened this file by 11 bytes moved two region offsets by 11 and read as a
    # behavioural difference.
    #
    # What remains in `lib/` is 53 regions of Ruby whose variable happens to be
    # named `token`, `session` or `pass` over a substantial value -- `unquote(value)`,
    # `Data.define(:prefix,` -- not a credential among them. The entropy residual
    # is blake3 digest fixtures in `spec/`, correctly hash-shaped, and long URLs
    # and paths in markdown, because `/`, `-` and `_` are all base64url characters.
    #
    # Recorded rather than special-cased: a documented residual beats a rule
    # nobody can reason about, and every region has a release path. The cost of a
    # false positive is one release decision, and the digest is what keeps it to
    # one across the whole run.
    #
    # == Recall, measured against the same shapes every time
    #
    # Found: `DATABASE_PASSWORD=hunter2`, `API_KEY=sk-...`, an AWS secret access
    # key, a `ghp_` token behind `token:`,
    # `SESSION_SECRET=correct-horse-battery-staple`, a bare 48-character base64
    # run, a 32-character hex key both bare and assigned, a PEM header, and a
    # quoted key (whose quotes stay out of the region).
    #
    # Not found, each deliberately: `x = 1`, `DEBUG = true`, `Note: this is
    # important`, `format = "terse"`, an rspec `let`, a UUID fixture, a long path,
    # a punctuation-only value, and a `word: text` line whose value is prose.
    #
    # == A JWT is three regions, and the first one is everybody's
    #
    # `.` is not in the token charset, so a bare JWT reports its header, payload
    # and signature separately. The header of every HS256 JWT is the identical
    # byte string `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9`, so under content-addressed
    # identity, releasing one JWT pre-releases the header segment of every future
    # JWT at that path. The payload and signature -- the parts that are actually
    # secret -- are unaffected.
    #
    # Joining `.`-separated runs into one region was measured and NOT taken: on
    # its own it makes a JWT report ZERO regions, because the base64 shape test
    # does not admit `.` either, so the joined token fails `high_entropy?`. Making
    # it work needs `.` in the shape test as well, which widens what counts as
    # base64 everywhere.
    #
    # == Cost
    #
    # ~0.27ms/KB on ordinary source (3.5ms for a 13.5KB file). Linear, with no
    # blowup on adversarial input: a single 1MB base64 line is 578ms and 4MB is
    # 2.1s. So this runs per read without a budget under a few hundred KB, and a
    # caller reading megabyte blobs should know the cost is linear in bytes.
    module Regions
      # A region no pattern named. Journaled as-is, so triage stays legible as
      # triage rather than reading like a matched credential.
      ENTROPY_REASON = "high-entropy token"

      # Hex maxes out at 4.0 bits/char, so it needs its own floor; a random
      # 32-char hex key sits at ~3.9 and a sha1 at ~3.74, and catching the second
      # to keep the first is the trade this asymmetry is worth. Base64 runs need
      # the higher floor because paths and URLs are base64url-legal and sit at
      # 4.0-4.2 -- at 4.0 the detector reported 41 `lib/` file paths as secrets.
      # `HEX_LENGTH` binds in BOTH directions, because {high_entropy?} has two
      # callers and only one of them is length-filtered. `entropy_candidates` is
      # `TOKEN`-filtered at `{20,}`, so on that path a shorter run never arrives
      # and this constant is inert. But an assignment's VALUE reaches the same
      # predicate through `qualifies? -> secret_shaped?` with no pre-filter, so at
      # 10 a line like `blob = 3f5a9c2e1d7b` reports a region and at 20 it does
      # not. An earlier edition of this comment claimed the constant bound only
      # upward; that was a coverage gap in the spec being read as a property of
      # the code, and there is now an example on the gate path.
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

        # One secret is one region however many detectors reach it: `API_KEY=sk-`
        # is a dotenv assignment, an issuer prefix, a credential assignment and a
        # high-entropy run, and reporting four would make the card's "exactly one
        # region" false and ask the human four times.
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
      # from `workspace/snapshot.rb:75` with the type word changed. Changing it
      # is the point: with `blob` a region's digest would BE a snapshot blob's
      # digest of the same bytes, silently sharing one keyspace between two
      # content-addressing schemes.
      #
      # The scheme word is `sensitive-region-v1` and NOT `blob`, deliberately. The
      # framing is git's shape and snapshot.rb's own comment says the header
      # exists TO domain-separate; reusing its type word would make a region's
      # digest identical to a snapshot blob's for the same bytes, merging two
      # content-addressing keyspaces that mean different things. The house
      # precedent is Hunk's `hunk-content-v1`/`hunk-span-v1`.
      #
      # A Region is shareable, but it can only be CONSTRUCTED on the main Ractor,
      # because `Ext.blake3_hex` is not ractor-safe -- the same recorded gap Hunk,
      # Fuzzy and Bm25 carry. Digesting eagerly moves that constraint from every
      # read of the digest to the one construction, which is what lets T14 cache
      # by digest in a loop; `Snapshot::Blob` makes the same trade.
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

        def to_s = "#<Lain::Sensitivity::Regions::Region #{start}+#{length} #{reason}>"
        alias inspect to_s
      end
    end
  end
end
