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
    # cost are all in docs/devs/architecture.md's "The secret boundary". Two things a
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
      # HERE, beside the detector and not in any caller that renders one,
      # because five callers mask -- the read path
      # ({Middleware::RedactSecretReads}), a survey's projection
      # ({Survey::Projection}) and others -- and a human has to recognise the
      # same thing in all of them.
      #
      # The `%d` is an ORDINAL, counting masked regions in reading order, and
      # never the byte length withheld: a length discloses how long the secret
      # is, which is a fact about the secret. The ordinal discloses only how many
      # there are, which the release prompt already tells the human.
      PLACEHOLDER = "<redacted:%d>"
      PLACEHOLDER_SHAPE = Regexp.new(Regexp.escape(PLACEHOLDER).sub("%d", "(\\d+)"))
      PLACEHOLDER_ONLY = /\A#{PLACEHOLDER_SHAPE}\z/
      PLACEHOLDER_STEM = PLACEHOLDER[/\A[^%]*/].freeze

      # A region no pattern named. Journaled as-is, so triage stays legible as
      # triage rather than reading like a matched credential.
      ENTROPY_REASON = "high-entropy token"

      # Not "the backtrack limit": the usual cause is fancy-regex's fixed backtracking stack.
      OVER_MASKED_REASON = "over-masked: %s could not be scanned to the end"
      # Below every shape's rank, so a region it reaches is named for the over-mask.
      OVER_MASKED_RANK = -1

      NAME_HINT = /pass|(?-i:_PWD)|secret|token|api[_-]?key|credential|auth|private|signature|session/i

      ALPHANUMERIC_RUN = /[A-Za-z0-9]/

      # A count, a content digest or a filesystem path under a name that
      # only hints (`token_count`, `session_id`) is not a secret. A name that
      # NAMES one never gets this: a password can be all digits or look like a path.
      # The test reads the name the assignment captured, so a dotted key such as
      # `db.password` takes the whole-match path and is never exempt.
      ORDINARY_VALUE = %r{\A(?:\d+|(?:blake3|sha\d+|md5):[0-9a-f]{4,128}|/[\w.@+-]+(?:/[\w.@+-]+)*/?)\z}i
      SECRET_WORDS = /pass(?!port)|secret|(?:\A|[_-])(?:credentials?|private|pwd|pw)(?:[_-]|\z)/i
      # Glued in any case, since `PRIVKEY` and `licensekey` name a secret and the
      # egress refusal reads this too. The ordinary words that end in `key` are
      # enumerated because no letter rule tells `monkey` from `masterkey`; each is
      # anchored to a word start, so `DaemonKey` and `commonKey` still name one.
      SECRET_NOUN_LAST = /(?:
        (?:\A|[_-]|(?<=[a-z0-9]))token
        | (?:\A|[_-]|(?<=[a-z0-9])(?<!\bmon|\btur|\bdon|\bjoc|\bhoc|\bwhis|\blac|\bmalar))key
      )\z/ix
      SECRET_NAMING = Regexp.union(SECRET_WORDS, SECRET_NOUN_LAST)
      HINTING_NAME = Regexp.union(NAME_HINT, SECRET_NOUN_LAST)
      # A bare `key` would hint `primary_key` and `sort_key`, so only the upper-case
      # suffix an environment variable carries hints, and only over a value mixing letters and digits.
      KEY_SUFFIX = /\A[A-Z][A-Z0-9_]*[A-Z0-9]_KEY\z/
      KEY_VALUE = %r{\A(?=[^0-9]*[0-9])(?=[^A-Za-z]*[A-Za-z])[A-Za-z0-9+/=_.-]+\z}

      # A bare token's key is sought only this far back, so a long line stays linear.
      KEY_WINDOW = 96
      # The prefix names the algorithm, so only a key that names a secret outweighs it.
      ALGORITHM_PREFIX = /(?:blake3|sha\d+|md5)[:=]\z/i
      USER_PASSWORD = /(?:\A|\s)(?:-u|--user)[ \t]*[^\s:]+:\z/

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
      # A line read both as plain and as grep output, since `env:DB_PASSWORD=x` and
      # `DB_PASSWORD=a:b:c` each split right only one way; either reading that qualifies is masked.
      ASSIGNMENTS = [CredentialPatterns::MARGIN, CredentialPatterns::INDENTED_LINE_LEAD].map do |lead|
        /\A#{lead}(?:export[ \t]+)?(?<key>[A-Za-z_][A-Za-z0-9_-]*)(?<separator>[ \t]*[:=][ \t]*)(?<value>\S.*)\z/m
      end.freeze
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
      # A lockfile's checksum is high-entropy by construction, so in a file the
      # policy calls checksums a value in one of these shapes leaves both the
      # entropy arm and the value-shape half of an assignment: hex sha1 or sha256,
      # an SRI sha256 or sha512 digest, go.sum's `h1:`. Only behind a key that
      # names a checksum, because the same hex under `token:` or `_authToken=` is
      # a secret. Lowercase hex at a digest's width is let through by shape
      # anywhere unless its nearest key hints, so this field matters for the
      # rest: SRI, `h1:`, uppercase hex.
      CHECKSUM = %r{sha256-[A-Za-z0-9+/]{43}=|sha512-[A-Za-z0-9+/]{86}==|h1:[A-Za-z0-9+/]{43}=|\h{64}|\h{40}}
      CHECKSUM_ALGORITHM = /sha(?:1|256|512)[:=]/
      # A key counts only where a field starts -- a line's indent, after `{`, or
      # after a `, ` -- so a checksum word inside a hinted value, a longer key or
      # a URL query names nothing.
      FIELD_START = /(?:^[ \t]*|\{[ \t]*|,[ \t]+)/
      CHECKSUM_WORD = /integrity|checksum|content-hash|shasum|hash|sha256|sha1|md5|digest|commit|reference|revision/
      CHECKSUM_KEY = /"?(?:#{CHECKSUM_WORD})"?[ \t]*[:=][ \t]*["']?/
      # yarn v1 writes `integrity <digest>` with no separator.
      YARN_INTEGRITY = /[ \t]+integrity[ \t]+/
      # The 2 grammars where a bare algorithm word is the key: Gemfile.lock's
      # `name (version) sha256=` and a Pipfile.lock hash list item.
      ALGORITHM_KEYED = /\) (?=sha256=)|^[ \t]*"(?=sha256:)/
      # yarn's `resolved "...tgz#<sha1>"` and Cargo's `source = "git+...#<commit>"`.
      URL_FRAGMENT = /(?:resolved|source)"?[ \t]*[:=]?[ \t]*"[^"\s#]*#/
      # Module and version are required: a bare `h1:` anywhere would exempt any 44 base64 characters.
      GO_SUM = /^\S+ v\S+ (?=h1:)/
      CHECKSUM_FIELD = /
        (?:#{FIELD_START}(?:#{CHECKSUM_KEY}|#{URL_FRAGMENT})|^#{YARN_INTEGRITY}|#{ALGORITHM_KEYED}|#{GO_SUM})
        (?<value>(?:#{CHECKSUM_ALGORITHM})?(?:#{CHECKSUM}))
      /x
      # Old yarn's integrity digest, and only behind that key: a sha1 is short enough
      # that no other key is trusted to name one.
      INTEGRITY_KEY = /#{FIELD_START}"?integrity"?[ \t]*[:=][ \t]*["']?|^#{YARN_INTEGRITY}/
      INTEGRITY_FIELD = %r{(?:#{INTEGRITY_KEY})(?<value>sha1-[A-Za-z0-9+/]{27}=)}
      # Ids a hosting API prints for its objects, let through only under the key that names one and
      # only in that id's shape: an ObjectId under `_id`, as Hugging Face prints it, or under `$oid`,
      # as mongoexport does, and a GitHub node id, whose bytes {NodeId} parses first. Any other value
      # under these keys is still judged as a token.
      OBJECT_ID_FIELD = /"(?:_id|\$oid)"[ \t]*:[ \t]*"(?<value>[0-9a-f]{24})"/
      NODE_ID_FIELD = %r{"(?:node_id|id)"[ \t]*:[ \t]*"(?<value>[A-Za-z0-9+/_=-]{12,})"}
      # Code that reads a secret is not one: a call of a snake_case or a namespaced function whose
      # arguments are all names, each compound or too short to be a value of substance. A bare
      # `word(`, a quoted argument and a plain word argument stay found, since each can be a secret.
      # Every piece of every name is a word or a small number, so a secret glued onto a name
      # (`cfg_<hex>`, `hunter2_pass(`, `.hunter2pass()`) is not taken for code.
      NAME_PIECE = /(?:[A-Za-z]{1,16}|\d{1,3})/
      SNAKE_NAME = /#{NAME_PIECE}(?:_#{NAME_PIECE})*/
      CALLEE = /(?:[a-z]{1,16}(?:_#{NAME_PIECE})+|_?#{SNAKE_NAME}(?:(?:::|\.)_?#{SNAKE_NAME})+)/
      # An argument's snake_case name has at most 3 pieces, since a passphrase is words joined by `_`.
      SHORT_SNAKE = /#{NAME_PIECE}(?:_#{NAME_PIECE}){0,2}/
      CALL_ARGUMENT = /[&*:]?(?:[A-Za-z_]\w{0,#{CredentialPatterns::SUBSTANCE_LENGTH - 2}}|
                       _?#{NAME_PIECE}(?:_#{NAME_PIECE}){1,2}|
                       _?#{SHORT_SNAKE}(?:(?:::|\.|->)#{SHORT_SNAKE})+)(?:\[\w{0,4}\])?/x
      CALL_VALUE = /\A#{CALLEE}\((?:#{CALL_ARGUMENT}(?:,[ \t]*#{CALL_ARGUMENT})*)?
                    (?:,|\)(?:\.#{SNAKE_NAME}\(\))*[?;]*)?\z/x
      # `.b` returns a NEW, MUTABLE String, so `frozen_string_literal` does not
      # reach this one and it has to be frozen by hand.
      BOM = "\xEF\xBB\xBF".b.freeze

      # Password shapes the content table has no name for. They stay here and
      # not in {CredentialPatterns}: the write side refuses on that table, and
      # these match a note that only says where a password lives
      # (`db_password: is stored in vault`), where a false hit here costs one
      # release decision rather than a refused write.
      PASSWORD_SHAPES = {
        "suffixed password key" =>
          /^#{CredentialPatterns::INDENTED_LINE_LEAD}[\w-]*[_-](?:password|passwd)[ \t]*:[ \t]+
           ["']?(?<value>[^\s"']+)/ix,
        "mysql password flag" => /\b(?:mysql|mysqldump|mysqladmin|mariadb)\b[^\n]*?[ \t]-p(?<value>[^\s-]\S*)/
      }.freeze

      # A reference or template is where a secret is read FROM, so masking it hides
      # a name and protects nothing. Whole values only: a prefix match would pass
      # `${X:-hunter2pass}` or `$hunter2pass`, which carry the secret themselves.
      # `$UPPER_NAME` is the common shape, so a dull all-caps value after `$` is an accepted miss.
      REFERENCE_VALUE = /\A#{CredentialPatterns::REFERENCE}\z/
      REFERENCE_CHECKED = ["quoted password key", "suffixed password key", "url credentials"].freeze

      # The literal assignment and everything after it rank last, below these
      # too, so a token an issuer shape names keeps that name inside a compound
      # assignment.
      CONTENT_SHAPES = CredentialPatterns.for(:content).then do |content|
        last = content.slice(*content.keys.drop_while { _1 != "credential literal assignment" })
        content.except(*last.keys).merge(PASSWORD_SHAPES, last)
      end.freeze

      # A value holding one of these is a secret whole. The gated password
      # shapes name a secret INSIDE their match, so a url or a header around one
      # would otherwise be masked entire along with its password.
      ISSUER_FIXED = CredentialPatterns::ISSUED.values.freeze

      # Issuer-fixed shapes are whole-match secrets; the assignment shapes are
      # gated and contribute only their value. Order is the table's own, so a
      # span both shapes reach is named by the one that says more.
      PATTERNS = CONTENT_SHAPES.keys.each_with_index.to_h.freeze

      # The shapes that name their secret's span, so only that group is masked.
      VALUED = CONTENT_SHAPES.select { _2.names.include?("value") }.keys.freeze

      class << self
        # The shapes read the {View}'s UTF-8 text, so `^` sees line 1 behind a BOM
        # and UTF-16 reads as the text it spells; each offset maps back to the
        # bytes the caller handed over. The raw bytes of a UTF-16 view are scanned
        # too, so ASCII next to UTF-16 text is found.
        #
        # @param content [String] file bytes in any encoding; re-tagged BINARY
        #   here rather than by the caller, because the credential table
        #   deliberately does not normalize and this is the consumer that needs
        #   it. Invalid UTF-8 is safe as a result.
        # @param checksums [Boolean] true for a file {Sensitivity::Policy#checksums?}
        #   names: a value in {CHECKSUM} shape behind a checksum key is no longer
        #   found by its entropy or value shape alone, while a name hint, an issuer
        #   shape and every other pattern still find it
        # @param hinted [Boolean] true when the content is a value a hinting name
        #   holds whole, so no token in it is excused for its digest shape
        # @return [Array<Region>] frozen, ascending by offset, no two overlapping
        def detect(content, checksums: false, hinted: false)
          bytes = content.b
          view = View.of(bytes)
          found = mapped(view, scan(view.text, checksums, hinted))
          found += scan(bytes, checksums, hinted) if view.utf16?

          # `:rank` makes the sort key TOTAL. No output depends on it -- equal
          # starts always overlap, so they merge, and `coalesced` picks the name
          # by rank anyway -- but `sort_by` is not stable, and without it the
          # fold's intermediate order is arbitrary. Deliberately unpinnable: no
          # mutant can kill it, which is the honest reason there is no spec.
          merge(found.sort_by { [_1[:start], _1[:rank]] }, bytes, view)
        end

        # @param text [String]
        # @return [Integer] how many placeholders it holds, a repeat counted each time
        def placeholders(text) = placeholder_spans(text).size

        # A fresh region numbers past every placeholder present, so one never
        # reuses a slot already standing for another secret.
        #
        # @param text [String]
        # @return [Enumerator<Integer>]
        def numbering_after(text) = ((highest(text) + 1)..).each

        # @param text [String]
        # @return [Integer] the largest placeholder number present, 0 when none
        def highest(text)
          view = View.of(text)
          [text.b, *(view.text if spelled?(text, view))].flat_map { _1.scan(PLACEHOLDER_SHAPE).flatten }
                                                        .map(&:to_i).max.to_i
        end

        # Where each of `secrets` recurs in `text`, raw or escaped as `inspect` would
        # escape it. Only a value of substance is sought, since a short one recurs in
        # ordinary words and the placeholders would spell it back out. An occurrence
        # touching a placeholder is dropped, because masking it would erase the slot.
        #
        # @param text [String]
        # @param secrets [Array<String>]
        # @return [Array<Spans::Span>]
        def recurrences(text, secrets)
          haystack = text.b
          view = View.of(haystack)
          standing = placeholder_spans(text)
          secrets.select { _1.bytesize >= CredentialPatterns::SUBSTANCE_LENGTH }.flat_map { spelled_in(_1, view) }.uniq
                 .flat_map { occurrences(haystack, _1) }
                 .reject { |span| standing.any? { span.start < _1.finish && _1.start < span.finish } }
        end

        # The UTF-8 spellings {.recurrences} seeks a value by: its bytes, and
        # its bytes as an escaped string literal holds them.
        #
        # @param value [String]
        # @return [Array<String>] BINARY
        def spellings(value) = [value.b, String.new(value, encoding: Encoding::UTF_8).inspect[1..-2].b]

        private

        # The ruling is "over-mask the span, never under-mask", so no gate or exemption may shrink one.
        def scan(scanned, checksums, hinted)
          over_masked, rows = RustScanner.default.scan(scanned).partition { _1[4] }
          candidates(scanned, group_by_shape(rows, scanned), checksums, hinted) + over_masked.map { over_mask(*_1) }
        end

        def over_mask(name, start, finish, *)
          { start:, finish:, reason: format(OVER_MASKED_REASON, name), detector: :pattern,
            rank: OVER_MASKED_RANK, over_masked_by: name }
        end

        def mapped(view, found)
          found.map { _1.merge(start: view.offset(_1[:start]), finish: view.end_offset(_1[:finish])) }
        end

        def merge(sorted, bytes, view)
          # Here and not in the CONTENT pattern, which a real value starting with `<` must still match.
          coalesce(sorted).map { region_at(_1, bytes) }.reject { placeholder?(_1.bytes, view) }.freeze
        end

        def placeholder?(bytes, view) = [bytes, view.decode(bytes)].any? { _1.match?(PLACEHOLDER_ONLY) }

        def placeholder_spans(text)
          haystack = text.b
          view = View.of(haystack)
          spans = placeholders_in(haystack) { |start, finish| [start, finish] }
          return spans unless spelled?(haystack, view)

          spans + placeholders_in(view.text) { |start, finish| [view.offset(start), view.end_offset(finish)] }
        end

        # Whether a UTF-16 view holds a placeholder, asked of the bytes so a view with none is never decoded.
        def spelled?(text, view) = view.utf16? && text.b.include?(view.encode(PLACEHOLDER_STEM))

        def placeholders_in(scanned)
          scanned.to_enum(:scan, PLACEHOLDER_SHAPE).map do
            found = Regexp.last_match
            start, finish = yield found.byteoffset(0)
            Spans::Span.new(start:, length: finish - start)
          end
        end

        def spelled_in(bytes, view)
          utf8 = spellings(bytes)
          return utf8 unless view.utf16?

          utf8 + utf8.map { String.new(_1, encoding: Encoding::UTF_8) }.select(&:valid_encoding?).map { view.encode(_1) }
        end

        def occurrences(haystack, needle)
          Enumerator.produce(haystack.byteindex(needle)) { haystack.byteindex(needle, _1 + needle.bytesize) }
                    .take_while(&:itself).map { Spans::Span.new(start: _1, length: needle.bytesize) }
        end

        # One secret is one region however many detectors reach it:
        # `API_KEY=sk-` is a dotenv assignment, an issuer prefix, a credential
        # assignment and a high-entropy run, and reporting four would ask the
        # human four times about one thing.
        def coalesce(sorted)
          spans = Spans.of(sorted.map { Spans::Span.new(start: _1[:start], length: _1[:finish] - _1[:start]) }).to_a
          starts = spans.map(&:start)
          sorted.group_by { owner(starts, _1[:start]) }.map { |index, group| named(spans.fetch(index), group) }
        end

        def owner(starts, start) = (starts.bsearch_index { _1 > start } || starts.size) - 1

        # The merged span takes the name of the higher-precedence shape, which is
        # not always the one that started first.
        def named(span, group) = group.min_by { _1[:rank] }.merge(start: span.start, finish: span.finish)

        def region_at(candidate, bytes)
          start = candidate[:start]
          Region.new(start:, bytes: bytes.byteslice(start, candidate[:finish] - start),
                     reason: candidate[:reason], detector: candidate[:detector],
                     over_masked_by: candidate[:over_masked_by])
        end

        def group_by_shape(rows, scanned)
          rows.each_with_object(Hash.new { |by_shape, name| by_shape[name] = [] }) do |row, by_shape|
            name, start, finish, groups = row
            by_shape[name] << Match.new(scanned, start, finish, groups)
          end
        end

        def candidates(scanned, matches_by_shape, checksums, hinted)
          public, disguised = matches_by_shape["PEM_PUBLIC"].partition { PublicKey.pem?(_1[1], _1[2]) }
          fields = checksums ? checksum_spans(matches_by_shape) : []
          allowed = fields + public_id_spans(matches_by_shape)
          entropy = outside(entropy_candidates(scanned, matches_by_shape, hinted), allowed)

          outside(pattern_candidates(matches_by_shape, fields) + entropy, public_spans(matches_by_shape, public)) +
            disguised.map { span(_1.begin(0), _1[0], DISGUISED_KEY, :pattern) }
        end

        def checksum_spans(matches_by_shape)
          %w[CHECKSUM_FIELD INTEGRITY_FIELD].flat_map { matches_by_shape[_1] }
                                            .map { _1.begin(:value)..._1.end(:value) }
        end

        def public_id_spans(matches_by_shape)
          node_ids = matches_by_shape["NODE_ID_FIELD"].select { NodeId.public?(_1[:value]) }
          (matches_by_shape["OBJECT_ID_FIELD"] + node_ids).map { _1.begin(:value)..._1.end(:value) }
        end

        def outside(candidates, spans)
          begins, widest = widest_reach(spans)
          candidates.reject do |candidate|
            index = owner(begins, candidate[:start])
            index >= 0 && widest[index].cover?(candidate[:start]...candidate[:finish])
          end
        end

        # Of the spans beginning at or before a point, the one ending last is
        # the only one that can cover a candidate starting there.
        def widest_reach(spans)
          sorted = spans.sort_by(&:begin)
          widest = sorted.each_with_object([]) do |span, kept|
            kept << (kept.last && kept.last.end > span.end ? kept.last : span)
          end
          [sorted.map(&:begin), widest]
        end

        def public_spans(matches_by_shape, blocks)
          openssh_spans(matches_by_shape) + blocks.map { _1.begin(0)..._1.end(0) }
        end

        def openssh_spans(matches_by_shape)
          matches_by_shape["OPENSSH_PUBLIC"].select { |key| PublicKey.openssh?(key[1], key[2]) }
                                            .map { _1.begin(1)..._1.end(2) }
        end

        def pattern_candidates(matches_by_shape, fields)
          CONTENT_SHAPES.each_key.flat_map do |name|
            matches_by_shape[name].flat_map { |match| pattern_candidate(name, match, fields) }
          end
        end

        def pattern_candidate(name, match, fields)
          return [value_group_span(match, name)].compact if VALUED.include?(name)

          readings = ASSIGNMENTS.filter_map { _1.match(match[0]) }
          return [span(match.begin(0), match[0], name, :pattern)] if readings.empty?

          readings.filter_map { assignment_candidate(name, match, _1, fields) }
        end

        def assignment_candidate(name, match, assignment, fields)
          return nil if reference?(assignment[:value])

          candidate = value_span(match, assignment, name)
          candidate if qualifies?(name, assignment, outside([candidate], fields).any?)
        end

        def value_group_span(match, name)
          return nil if REFERENCE_CHECKED.include?(name) && !real_value?(match[:value])

          span(match.begin(:value), match[:value], name, :pattern)
        end

        def reference?(value) = unquote(value).match?(REFERENCE_VALUE)

        def real_value?(value) = !reference?(value) && substantial?(value)

        # The emitted span is the UNQUOTED value. Quotes are the file's syntax,
        # not the secret: masking a span that carries its own delimiters would
        # destroy the quoting that made the file parse, and a quoted and an
        # unquoted copy of one secret would address differently.
        def value_span(match, assignment, name)
          value = assignment[:value]
          emitted = unquote(value)
          within = assignment.byteoffset(:value).first + value.byteindex(emitted)

          span(match.begin(0) + within, emitted, name, :pattern)
        end

        # `shaped` is false for a value inside a checksum field, which its shape alone no longer qualifies.
        def qualifies?(name, assignment, shaped)
          key, value = assignment.values_at(:key, :value)
          value_shaped = shaped && secret_shaped?(value)
          return value_shaped if VALUE_GATED_ONLY.include?(name)

          (hinted?(assignment) && substantial?(value) && !ordinary?(key, value) && !value.match?(CALL_VALUE)) ||
            value_shaped
        end

        # The `_KEY` hint needs a glued `=`, as a shell needs it and a Ruby constant is not written.
        def hinted?(assignment)
          key, separator, value = assignment.values_at(:key, :separator, :value)

          key.match?(NAME_HINT) || (key.match?(KEY_SUFFIX) && separator == "=" && unquote(value).match?(KEY_VALUE))
        end

        def ordinary?(key, value) = !key.match?(SECRET_NAMING) && unquote(value).match?(ORDINARY_VALUE)

        def substantial?(value)
          token = unquote(value)

          token.bytesize >= CredentialPatterns::SUBSTANCE_LENGTH && token.match?(ALPHANUMERIC_RUN)
        end

        def entropy_candidates(scanned, matches_by_shape, hinted)
          matches_by_shape["TOKEN"].select { secret_shaped?(_1[0], hinted: hinted || digest_hinted?(scanned, _1)) }
                                   .map { span(_1.begin(0), _1[0], ENTROPY_REASON, :entropy) }
        end

        # The key changes the answer only for a digest-width token, and finding it costs a walk.
        def digest_hinted?(scanned, match) = match[0].match?(Entropy::DIGEST_HEX) && hinted_at?(scanned, match.begin(0))

        def hinted_at?(scanned, start)
          lead = scanned.byteslice([start - KEY_WINDOW, 0].max...start)
          return true if lead.match?(USER_PASSWORD)

          prefix = lead.match(ALGORITHM_PREFIX)
          key = NearestKey.of(prefix ? prefix.pre_match : lead)
          !key.nil? && key.match?(prefix ? SECRET_NAMING : HINTING_NAME)
        end

        def span(start, text, reason, detector)
          { start:, finish: start + text.bytesize, reason:, detector:,
            rank: detector == :entropy ? PATTERNS.size : PATTERNS.fetch(reason) }
        end

        def secret_shaped?(value, hinted: false)
          token = unquote(value)

          issuer_fixed?(token) || (Entropy.high?(token) && !Entropy.predictable?(token, hinted:))
        end

        # Quotes belong to the file's syntax, not to the secret. Left on, a short
        # dull value clears the length floor on its own delimiters.
        def unquote(value)
          value.strip.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
        end

        def issuer_fixed?(token) = ISSUER_FIXED.any? { token.match?(_1) }
      end

      # 1 scanner row, read through the part of `MatchData` the steps above use. A group that took
      # no part reads as nil, as it does on a `MatchData`.
      class Match
        # @param scanned [String] the bytes the row's offsets index
        # @param start [Integer]
        # @param finish [Integer]
        # @param groups [Hash{String => Array(Integer, Integer)}]
        def initialize(scanned, start, finish, groups)
          @scanned = scanned
          @whole = [start, finish]
          @groups = groups
        end

        # @param key [Integer, String, Symbol] 0 for the whole match, else a group's name or number
        # @return [String, nil]
        def [](key) = (range = span(key)) && @scanned.byteslice(range[0]...range[1])

        # @param key [Integer, String, Symbol]
        # @return [Integer, nil]
        def begin(key) = span(key)&.first

        # @param key [Integer, String, Symbol]
        # @return [Integer, nil]
        def end(key) = span(key)&.last

        private

        def span(key) = key.equal?(0) ? @whole : @groups[key.to_s]
      end
      private_constant :Match

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

      # Whether a value is a GitHub node id, parsed exactly. The legacy form is base64 of
      # `<type length>:<Type><number>`; the current form is a type prefix and base64url of a
      # msgpack array of unsigned integers whose first is 0. Anything else is not an id.
      module NodeId
        LEGACY = /\A(?<length>\d{2,3}):(?<type>[A-Z][A-Za-z]+)\d+\z/
        TYPED = /\A[A-Z]{1,8}_(?<payload>[A-Za-z0-9_-]+)\z/
        # A msgpack unsigned integer's lead byte, and how many bytes follow it.
        UINT_WIDTHS = { 0xcc => 1, 0xcd => 2, 0xce => 4, 0xcf => 8 }.freeze

        module_function

        # @param value [String]
        def public?(value) = legacy?(value) || typed?(value)

        def legacy?(value)
          id = LEGACY.match(value.unpack1("m0"))
          !id.nil? && id[:length].to_i == id[:type].size
        rescue ArgumentError
          false
        end

        def typed?(value)
          payload = TYPED.match(value)&.[](:payload)
          !payload.nil? && uint_array?(decoded(payload))
        rescue ArgumentError
          false
        end

        def decoded(payload)
          base64 = payload.tr("-_", "+/")
          "#{base64}#{"=" * (-base64.size % 4)}".unpack1("m0")
        end

        def uint_array?(bytes)
          count = bytes.getbyte(0).to_i - 0x90
          (1..15).cover?(count) && bytes.getbyte(1).to_i.zero? &&
            count.times.inject(1) { |at, _| at && uint_end(bytes, at) } == bytes.bytesize
        end

        def uint_end(bytes, at)
          lead = bytes.getbyte(at)
          return nil if lead.nil?
          return at + 1 if lead < 0x80

          UINT_WIDTHS[lead]&.then { at + 1 + _1 }
        end
      end
      private_constant :NodeId

      # The name a bare token sits under. A value often sits away from its key: on
      # the line after it, inside brackets, a call or a nested object, behind a YAML
      # tag, or after an earlier value in the same list. So the walk back passes
      # punctuation, earlier values and the generic words `value` and `bearer`, and
      # stops at the first other word. A line break counts only with a separator
      # beside it, or the last word of the line before would name the token. A word
      # holding `/` is a path a digest tool printed, so it names nothing.
      module NearestKey
        PIECE = %r{[A-Za-z0-9_][\w.+/-]*|[^A-Za-z0-9_]+}
        GAP = /\A[\s"'`>|\-\[\](){},=!:]+\z/
        GENERIC = /\A(?:value|bearer)\z/i

        module_function

        # @param lead [String] the bytes before a token, already bounded
        # @return [String, nil] the nearest name, or nil when none stands there
        def of(lead)
          pieces = lead.scan(PIECE).reverse
          stop = pieces.each_index.find { |at| !passable?(pieces[at], pieces[at + 1]) }
          key = stop && pieces[stop]
          key if key && !key.include?("/") && separated?(pieces.first(stop).join)
        end

        def passable?(piece, before)
          piece.match?(GAP) || piece.match?(GENERIC) || before.to_s.end_with?("!") || Entropy.high?(piece)
        end

        def separated?(gap) = !gap.include?("\n") || gap.match?(/[:=]/)
      end
      private_constant :NearestKey

      Region = Data.define(:start, :bytes, :reason, :detector, :digest, :over_masked_by)

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
          Canonical.digest_bytes("#{SCHEME} #{bytes.bytesize}\0".b + bytes)
        end

        # A region a scan could not finish is masked whole, and its `over_masked_by` names the shape;
        # for a region a match or the entropy detector found it is nil.
        def initialize(start:, bytes:, reason:, detector:, over_masked_by: nil)
          raise ArgumentError, "unknown detector #{detector.inspect}: expected #{DETECTORS.inspect}" \
            unless DETECTORS.include?(detector)

          content = -bytes.b
          super(start: Integer(start), bytes: content, reason: -reason.to_str, detector:,
                digest: Region.address(content), over_masked_by: over_masked_by&.then { -_1.to_str })
        end

        def length = bytes.bytesize

        # Triage, not a match. The Journal and the release prompt both need to
        # say which one this was without comparing a reason string.
        def entropy? = detector == :entropy

        # Never the bytes -- but note what it DOES render: offset, length and
        # the detector's reason. That is safe in a backtrace and unsafe in a
        # prompt, so no human-facing string may interpolate a Region.
        # {Approval::Parked::Queue::Outstanding#preamble} says WHICH file and HOW MANY
        # for exactly that reason, and a future `"#{outstanding}"` written for
        # convenience would undo it by disclosing where in the file each secret
        # sits and how long it is.
        def to_s = "#<Lain::Sensitivity::Regions::Region #{start}+#{length} #{reason}>"
        alias inspect to_s
      end
    end
  end
end
