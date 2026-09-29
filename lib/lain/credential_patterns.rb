# frozen_string_literal: true

module Lain
  # The one table of credential shapes, selected per consumer. A single
  # undifferentiated constant cannot satisfy both truths at once: the sides must
  # not drift apart, and the read side needs shapes the write side must not gain.
  #
  # `for(:write)` guards {Middleware::RefuseSecretWrites}, which refuses a user's
  # own prose, so every shape in it is gated on a credential NAME or an
  # issuer-fixed prefix. `for(:content)` adds assignment shapes and runs over file
  # BYTES, where an unrecognized `KEY=value` is exactly the risk and no prose is
  # being refused -- widening the write side with them would start refusing
  # `memory_write` on any note containing `foo: bar`.
  #
  # The assignment shapes are named for their SYNTAX rather than a credential,
  # because that is what they honestly detect: the name is what gets journaled
  # and put in a model-facing error, and calling a matched `foo: bar` a
  # credential teaches the model the wrong lesson.
  #
  # ENCODING CONTRACT: hand `for(:content)` BINARY bytes -- `File.binread`, not
  # `File.read`. Every shape is pure ASCII, so the regexps are US-ASCII with
  # `fixed_encoding?` false and match any ASCII-compatible encoding, ASCII-8BIT
  # included. What they cannot survive is a String whose declared encoding
  # disagrees with its bytes: invalid UTF-8 raises ArgumentError, and UTF-16
  # raises Encoding::CompatibilityError while `valid_encoding?` answers TRUE --
  # which is why a caller cannot use that predicate to decide a scan is safe.
  # Binary bytes have neither failure mode. This table deliberately does not
  # normalize: one that re-encoded its input would hide which consumer needed it.
  module CredentialPatterns
    # A refusal that came from a judgment rather than a named pattern is not a
    # pattern hit. {Telemetry::WriteRefused} requires `pattern` non-nil, so a
    # decline carries a reason from this reserved namespace instead -- and no
    # pattern name may collide with it, or a genuine credential hit reads as a
    # judgment call.
    #
    # {Telemetry::WriteRefused} owns the FIELD and could have held the prefix,
    # but the prefix constrains what may be a pattern NAME and the names are
    # here. Telemetry describes a record's shape and never inspects a
    # vocabulary; the rule would sit apart from the only data that can violate it.
    DECLINE_PREFIX = "decline:"

    # @param reason [String] a journaled {Telemetry::WriteRefused#pattern}
    # @return [Boolean] true if a judgment declined the write, false if a
    #   credential pattern matched it
    def self.decline?(reason) = reason.start_with?(DECLINE_PREFIX)

    # Every set is built through this, so a new one cannot skip the check, which
    # asserts through {.decline?} itself rather than a second spelling of it.
    #
    # @param patterns [Hash{String => Regexp}]
    # @return [Hash{String => Regexp}] frozen
    def self.unreserved(patterns)
      reserved = patterns.keys.select { |name| decline?(name) }
      raise "credential patterns may not use the reserved #{DECLINE_PREFIX.inspect} namespace: #{reserved.inspect}" \
        unless reserved.empty?

      patterns.freeze
    end

    # The sk- shape is anchored with a lookbehind because unanchored it matched
    # INSIDE hyphenated prose ("ask-someone-to-help-..."), refusing a benign
    # write under a pattern name it never honestly matched: a real key stands
    # alone, never run into by a preceding word char or hyphen.
    #
    # The key block is one span from BEGIN through its END, because the read
    # side masks the span: matching the header alone left each base64 line to
    # the entropy detector, which misses a short last line -- half the 3072-bit
    # PKCS#8 keys `openssl genrsa` writes kept their tail in a masked read.
    # Text that ends before an END is covered to its end, since a bounded read
    # or a window can cut a block off; the write side still refuses on the
    # header alone.
    WRITE = unreserved(
      "openai-style api key" => /(?<![\w-])sk-[A-Za-z0-9_-]{16,}/,
      "aws access key id" => /AKIA[0-9A-Z]{16}/,
      "pem private key block" => /-----BEGIN(?: [A-Z]+)? PRIVATE KEY-----(?:.*?-----END [A-Z ]*PRIVATE KEY-----|.*)/m,
      "credential assignment" => /\b(?:password|passwd|secret|api[_-]?key|token)\s*[:=]\s*\S+/i
    )

    # Name-agnostic on purpose, and the reason these stay off the write side: a
    # compound environment-variable name has no word boundary before "PASSWORD",
    # so WRITE's name-gated shape cannot see `DATABASE_PASSWORD=` at all, and
    # gating these on a name vocabulary would reproduce that blind spot over the
    # file bytes where it matters most. `^` is line-anchored, which is what lets
    # one scan cover a whole file.
    #
    # KNOWN IMPRECISION, measured rather than estimated. The argument above
    # carries the dotenv shape, which needs an `=`; it does not equally carry the
    # yaml shape, which needs only a colon and a space and so matches any prose
    # line of `word: text`. Over this repo's own markdown -- 134 files, `**/*.md`
    # less `references/repos/` and `.claude/` -- `for(:content)` matches 95, of
    # which the yaml shape alone accounts for 90, against 7 for `for(:write)`.
    #
    # Recorded rather than fixed on two grounds: the name claims a syntax and not
    # a credential, so it stays honest, and nothing here reaches the write side,
    # so no prose is refused over it. A consumer that cannot tolerate the rate
    # narrows at ITS end -- by file type, say -- not by widening a name here.
    ASSIGNMENTS = unreserved(
      "dotenv assignment" => /^[ \t]*(?:export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*\S+/,
      "toml assignment" => /^[ \t]*[A-Za-z_][A-Za-z0-9_-]*[ \t]*=[ \t]*(?:"[^"]*"|'[^']*')/,
      "yaml assignment" => /^[ \t]*[A-Za-z_][A-Za-z0-9_-]*:[ \t]+\S+/
    )

    # Credential files whose lines carry no `=` or `: ` for the assignment shapes
    # to key on. The secret is the named `value` group, so a detector can mask it
    # alone. Each is anchored to its own file grammar: a netrc entry needs
    # both a `login` and a `password`, a pgpass line is exactly five fields with a
    # numeric or `*` port, a non-numeric host and only `\:` escaping a colon in
    # a field, and an htpasswd value must be a crypt or `{SHA}` hash. That
    # keeps `/etc/passwd`, `/etc/shadow` and timestamped log lines region-free.
    #
    # KNOWN IMPRECISION for msmtprc: a bare `password <word>` line has no
    # neighbour that could confirm the file, and it must stay a region because
    # that is the whole grammar, so a prose line such as `password required` is
    # masked. Recorded rather than narrowed, on the ground that a false mask costs
    # one release decision and a missed credential costs the credential. A netrc
    # entry with no `login` is likewise not seen, because requiring one is what
    # keeps `default password reset` prose clean.
    FILE_FORMATS = unreserved(
      "netrc password" => /\b(?:machine[ \t]+\S+|default)[ \t]+
        (?:login[ \t]+\S+[ \t]+password[ \t]+(?<value>\S+)|
        password[ \t]+(?<value>\S+)[ \t]+login[ \t]+\S+)/x,
      "pgpass entry" => /^(?!\d+:)(?:[^\s:\\]|\\.)+:(?:\d+|\*):[^\s:]+:[^\s:]+:(?<value>(?:[^\s:\\]|\\.)+)$/,
      "htpasswd hash" => /^[^\s:]+:(?<value>\$(?:apr1|2[abxy]|[156])\$\S+|\{SHA\}\S+)$/,
      "msmtprc password" => /^[ \t]*password[ \t]+(?<value>\S+)[ \t]*$/
    )

    CONTENT = unreserved(WRITE.merge(ASSIGNMENTS, FILE_FORMATS))

    # WRITE first, so a line that is both an assignment and a known issuer
    # prefix is journaled under the shape that says more.
    SETS = { write: WRITE, content: CONTENT }.freeze

    # @param consumer [Symbol] `:write` or `:content`
    # @return [Hash{String => Regexp}] frozen; name => shape
    def self.for(consumer)
      SETS.fetch(consumer) do
        raise ArgumentError, "unknown credential-pattern consumer #{consumer.inspect}: expected #{SETS.keys.inspect}"
      end
    end
  end
end
