# frozen_string_literal: true

require "openssl"

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
      # Public-key material is public by definition, and its base64 blob is
      # exactly the run the entropy detector exists to find -- so every `.pub`,
      # known_hosts and authorized_keys file reported a region, `read_file`
      # parked on it, and automatic approval refused `cat id_ed25519.pub`. A
      # candidate wholly inside one of these spans is dropped; one reaching
      # past it is kept. The OpenSSH span is the type and the blob, never the
      # comment after them. A shape is only a claim, so {PublicKey} parses
      # what it claims before any span is granted.
      # Public armour around anything that is not a public key -- a relabelled
      # private body, or no DER at all -- is one region, named for what such a
      # block is most likely to be, and whole for the reason that shape's own
      # span is: line by line, a short last line survives the entropy detector.
      DISGUISED_KEY = "pem private key block"
      OPENSSH_PUBLIC = %r{(?<![\w-])((?:ssh|ecdsa-sha2|sk)-[a-z0-9@.-]+) (AAAA[A-Za-z0-9+/]+={0,3})(?![A-Za-z0-9+/=])}
      PEM_PUBLIC = %r{-----BEGIN ((?:RSA )?PUBLIC KEY)-----\r?\n([A-Za-z0-9+/=\r\n]+)-----END \1-----}
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

        def candidates(scanned)
          public, disguised = matches(scanned, PEM_PUBLIC).partition { |block| PublicKey.pem?(block[1], block[2]) }

          outside(pattern_candidates(scanned) + entropy_candidates(scanned), public_spans(scanned, public)) +
            disguised.map { span(_1.begin(0), _1[0], DISGUISED_KEY, :pattern) }
        end

        def outside(candidates, spans)
          candidates.reject { |candidate| spans.any? { _1.cover?(candidate[:start]...candidate[:finish]) } }
        end

        def public_spans(scanned, blocks) = openssh_spans(scanned) + blocks.map { _1.begin(0)..._1.end(0) }

        def openssh_spans(scanned)
          matches(scanned, OPENSSH_PUBLIC).select { |key| PublicKey.openssh?(key[1], key[2]) }
                                          .map { _1.begin(1)..._1.end(2) }
        end

        def pattern_candidates(scanned)
          CredentialPatterns.for(:content).flat_map do |name, shape|
            matches(scanned, shape).filter_map { |match| pattern_candidate(name, match) }
          end
        end

        # `String#to_enum(:scan)` is what exposes `Regexp.last_match` per
        # iteration; `scan` alone yields text without offsets.
        def matches(scanned, shape) = scanned.to_enum(:scan, shape).map { Regexp.last_match }

        def pattern_candidate(name, match)
          return value_group_span(match, name) if match.names.include?("value")

          assignment = ASSIGNMENT.match(match[0])
          return span(match.begin(0), match[0], name, :pattern) unless assignment

          return nil unless qualifies?(name, assignment[1], assignment[2])

          value_span(match, assignment, name)
        end

        def value_group_span(match, name) = span(match.begin(:value), match[:value], name, :pattern)

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

      # Whether bytes that look like a public key ARE one, parsed exactly. The
      # exemption above unmasks whatever it covers, so a label or a type word
      # is never enough: a private seed written in a public key's layout, a
      # payload after the type, a token glued onto a real blob, and a private
      # body under public armour must all stay regions. Every field a type
      # defines must be present and nothing may follow them; a type not listed
      # here, and any failure to parse, is not public.
      module PublicKey
        ANY = ->(bytes) { !bytes.empty? }
        ED25519 = ->(bytes) { bytes.bytesize == 32 }

        def self.curve(name) = ->(bytes) { bytes == name }

        # The fields after the type string, in the RFC 4253, 5656 and 8709
        # wire layouts and OpenSSH's PROTOCOL.u2f for the security-key types,
        # whose last field is the application string.
        OPENSSH = {
          "ssh-ed25519" => [ED25519],
          "ssh-rsa" => [ANY, ANY],
          "ecdsa-sha2-nistp256" => [curve("nistp256"), ANY],
          "ecdsa-sha2-nistp384" => [curve("nistp384"), ANY],
          "ecdsa-sha2-nistp521" => [curve("nistp521"), ANY],
          "sk-ssh-ed25519@openssh.com" => [ED25519, ANY],
          "sk-ecdsa-sha2-nistp256@openssh.com" => [curve("nistp256"), ANY, ANY]
        }.freeze

        # SubjectPublicKeyInfo is an algorithm and a BIT STRING; RSAPublicKey is
        # a modulus and an exponent. Both private forms open with a version
        # INTEGER and carry more members, so neither can pass as these.
        PEM = {
          "PUBLIC KEY" => lambda do |node|
            node.is_a?(OpenSSL::ASN1::Sequence) && node.value.size == 2 &&
              node.value[0].is_a?(OpenSSL::ASN1::Sequence) &&
              node.value[0].value.first.is_a?(OpenSSL::ASN1::ObjectId) &&
              node.value[1].is_a?(OpenSSL::ASN1::BitString)
          end,
          "RSA PUBLIC KEY" => lambda do |node|
            node.is_a?(OpenSSL::ASN1::Sequence) && node.value.size == 2 &&
              node.value.all?(OpenSSL::ASN1::Integer)
          end
        }.freeze

        module_function

        # @param type [String] the key-type word
        # @param blob [String] its base64, which must be canonical
        def openssh?(type, blob)
          fields = OPENSSH.fetch(type, nil)
          strings = fields && exact_strings(blob.unpack1("m0"), fields.size + 1)

          !strings.nil? && strings.first == type && fields.zip(strings.drop(1)).all? { |field, got| field.call(got) }
        rescue ArgumentError
          false
        end

        # @param label [String] `PUBLIC KEY` or `RSA PUBLIC KEY`
        # @param body [String] the armoured base64
        def pem?(label, body)
          PEM.fetch(label).call(OpenSSL::ASN1.decode(body.delete("\r\n").unpack1("m0")))
        rescue StandardError
          false
        end

        # `count` length-prefixed strings, or nil unless they consume `bytes`
        # exactly. A length running past the end overshoots the offset, so one
        # comparison refuses both a short blob and a trailing payload.
        def exact_strings(bytes, count)
          strings, offset = count.times.inject([[], 0]) do |(read, at), _|
            length = bytes.byteslice(at, 4)&.unpack1("N") || bytes.bytesize
            [read << bytes.byteslice(at + 4, length).to_s, at + 4 + length]
          end
          strings if offset == bytes.bytesize
        end
      end
      private_constant :PublicKey

      Region = Data.define(:start, :bytes, :reason, :detector, :digest)

      # One sensitive span, and the digest that is its identity.
      #
      # The digest is of the region's OWN BYTES and never of its offset: a line
      # inserted above a secret must not invalidate it, or a region's address
      # would be whole-file behavior wearing a region's name.
      #
      # The framing is git's -- a type word, the byte length, a NUL -- the same
      # one {ContentAddressed::Blob} builds, with the type word deliberately
      # changed to `sensitive-region-v1`. That class exists TO domain-separate;
      # reusing `blob` would make a region's digest identical to a snapshot
      # blob's for the same bytes, silently merging two content-addressing
      # keyspaces. The house precedent is Hunk's
      # `hunk-content-v1`/`hunk-span-v1`. Still hand-rolled below rather than
      # built through that class -- the migration is its own change.
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
