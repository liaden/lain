# frozen_string_literal: true

module Lain
  # The one table of credential shapes, selected per consumer.
  #
  # Two things are both true and a single undifferentiated constant can only
  # satisfy one of them: the sides must not drift apart, and the read side
  # needs shapes the write side must not gain. So there is one place to read
  # and an explicit statement of which shapes each side uses.
  #
  # `for(:write)` guards {Middleware::RefuseSecretWrites}, which refuses a
  # user's own prose, so every shape in it is gated on a credential NAME or an
  # issuer-fixed prefix. `for(:content)` adds assignment shapes and runs over
  # file BYTES, where an unrecognized `KEY=value` is exactly the risk and no
  # prose is being refused -- widening the write side with them would start
  # refusing `memory_write` on any note containing `foo: bar`.
  #
  # The assignment shapes are named for their syntax rather than for a
  # credential, because that is what they honestly detect: the NAME is what
  # gets journaled and put in a model-facing error, and calling a matched
  # `foo: bar` a credential teaches the model the wrong lesson.
  #
  # ENCODING CONTRACT: hand `for(:content)` BINARY bytes -- `File.binread`,
  # not `File.read`. Every shape here is pure ASCII, so the regexps are
  # US-ASCII with `fixed_encoding?` false and match any ASCII-compatible
  # encoding, ASCII-8BIT included. What they cannot survive is a String whose
  # declared encoding disagrees with its bytes: invalid UTF-8 raises
  # ArgumentError, and UTF-16 raises Encoding::CompatibilityError while
  # `valid_encoding?` answers TRUE -- the same trap {Approval::Risk} documents,
  # and the reason a caller cannot use that predicate to decide a scan is safe.
  # Bytes read as binary have neither failure mode. Normalizing here is
  # deliberately not done: a table that re-encodes its input hides which
  # consumer needed it.
  module CredentialPatterns
    # A refusal that came from a judgment rather than from a named pattern is
    # not a pattern hit. {Telemetry::WriteRefused} requires `pattern` non-nil,
    # so a decline carries a reason from this reserved namespace instead --
    # and no pattern name may collide with it, or a genuine credential hit
    # reads as a judgment call. Defined here rather than on the middleware
    # because the table's own load-time guard needs it, and the table loads
    # first.
    #
    # {Telemetry::WriteRefused} owns the FIELD and loads earlier still, so it
    # could have held the prefix -- but the prefix is a constraint on what may
    # be a pattern NAME, and the names are here. Telemetry describes the
    # record's shape and never inspects a vocabulary; putting the rule there
    # would separate the invariant from the only data that can violate it.
    DECLINE_PREFIX = "decline:"

    # @param reason [String] a journaled {Telemetry::WriteRefused#pattern}
    # @return [Boolean] true if a judgment declined the write, false if a
    #   credential pattern matched it
    def self.decline?(reason) = reason.start_with?(DECLINE_PREFIX)

    # Every set is built through this, so a new one cannot be added without the
    # check. The invariant is asserted through {.decline?} itself so it cannot
    # test something subtly different from what readers call.
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
    WRITE = unreserved(
      "openai-style api key" => /(?<![\w-])sk-[A-Za-z0-9_-]{16,}/,
      "aws access key id" => /AKIA[0-9A-Z]{16}/,
      "pem private key block" => /-----BEGIN(?: [A-Z]+)? PRIVATE KEY-----/,
      "credential assignment" => /\b(?:password|passwd|secret|api[_-]?key|token)\s*[:=]\s*\S+/i
    )

    # Name-agnostic on purpose, and the reason these stay off the write side.
    # A compound environment-variable name has no word boundary before
    # "PASSWORD", so WRITE's name-gated shape cannot see `DATABASE_PASSWORD=`
    # at all; gating these on a name vocabulary would reproduce that blind spot
    # over the file bytes where it matters most. `^` is line-anchored, which is
    # what lets one scan cover a whole file.
    #
    # KNOWN IMPRECISION, measured rather than estimated. That argument carries
    # the dotenv shape, which needs an `=`; it does NOT equally carry the yaml
    # shape, which needs only a colon and a space and so matches any prose line
    # of `word: text`. Over this repo's own markdown -- `**/*.md` less
    # `references/repos/` and `.claude/`, 134 files -- `for(:content)` matches
    # 95, of which the yaml shape alone accounts for 90, against 7 for
    # `for(:write)`. `"TODO: fix this"` journals as `"yaml assignment"`.
    #
    # Recorded rather than fixed, on two grounds: the name claims a syntax and
    # not a credential, so it stays honest where the escalation trigger's own
    # bug did not, and nothing here reaches the write side, so no prose is
    # refused over it. A consumer that cannot tolerate that rate should narrow
    # at ITS end -- by file type, say -- rather than by widening a name here.
    ASSIGNMENTS = unreserved(
      "dotenv assignment" => /^[ \t]*(?:export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*\S+/,
      "toml assignment" => /^[ \t]*[A-Za-z_][A-Za-z0-9_-]*[ \t]*=[ \t]*(?:"[^"]*"|'[^']*')/,
      "yaml assignment" => /^[ \t]*[A-Za-z_][A-Za-z0-9_-]*:[ \t]+\S+/
    )

    CONTENT = unreserved(WRITE.merge(ASSIGNMENTS))

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
