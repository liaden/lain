# frozen_string_literal: true

require "pathname"

module Lain
  # Is this path ordinary, worth a gate, or off limits entirely -- decided from
  # the NAME alone. It is the first of the secret boundary's three arms: gate on
  # the effect here, filter the result in {Middleware::WithholdSecretPaths},
  # mask the content in {Middleware::RedactSecretReads}. The split is forced
  # rather than chosen -- a path classifier can answer before a file is opened
  # and a region detector cannot until it has the bytes.
  #
  # Several callers need the answer BEFORE the file is opened:
  # {Middleware::Sensitivity} refuses a denied read before any approval,
  # {Sensitivity::Policy} decides whether a tool call reaches a human, and
  # {Approval::Escalation::Triage} reads it off a parsed argv. So the classifier
  # does no IO at all -- no `stat`, no `realpath`, no entropy over the bytes --
  # and is free to call from any of them, in any order, as often as they like.
  # {#rooted} and {TILDE_SEGMENT} hold the rewriting that keeps it that way.
  #
  # Lexical matching is a decision, not an omission: a symlink named `notes.md`
  # pointing at `~/.ssh/id_ed25519` classifies ordinary. It is what
  # {Approval::Risk::Root} already chose so that it agrees with
  # {Workspace::Restore} about what "outside the root" means, and
  # resolving links here would both disagree with that and put a syscall in a
  # classifier whose whole contract is that it makes none. The hole has a name
  # and a spec rather than a stat -- and the one caller that cannot afford it
  # closes it on its own side: {Approval::ComposedTerm} resolves a word and
  # classifies where it LANDS as well as what it says, because nobody is asked
  # about what that rule approves.
  #
  # The two halves err in OPPOSITE directions. {Approval::Risk}'s widen-never-
  # sharpen rule (`risk.rb:66-72`) applies to the GATED half only, where a
  # spurious match costs one prompt. That price is the READ path's, which was
  # the only path when it was written: a caller that APPROVES pays the other
  # error instead, and a gated name this table does not match costs it an
  # unsupervised read of a credential rather than a prompt. So "one prompt" is
  # what a spurious match costs HERE, never what a miss costs everywhere.
  #
  # No policy, no `/mode auto` and no `ApproveAll` lifts a DENIAL, so a false
  # positive there makes a file permanently unreadable with no move available
  # to anyone -- which is why
  # `id_*` carries a `*.pub` exception, and why {DENIED} is split by how
  # AMBIGUOUS a name is rather than by where the secret usually lives.
  class Sensitivity
    include Declarative

    Verdict = Data.define(:level, :reason)

    # What the classifier answers. Frozen and shareable by being a Data of
    # Symbols, so it journals and crosses a Ractor as-is.
    class Verdict
      include Declarative

      # The constants live on this reopen rather than in a `Data.define` block,
      # where they would scope to {Sensitivity} instead (see
      # {Request::SYSTEM_PREFIX}).
      LEVELS = %i[ordinary gated denied].freeze
      # The reason is a Symbol from a closed set rather than a sentence, because
      # {Telemetry::ReadRefused} aggregates over it and a human reads
      # {#explanation}. `configured` and `exempt` name the config as the author
      # deliberately: "why is my file denied?" is answerable without us.
      EXPLANATIONS = {
        none: "ordinary",
        credential: "a credential-shaped name",
        out_of_scope: "a personal directory outside any project",
        protected: "a protected path",
        configured: "named by this project's sensitivity config",
        exempt: "exempted by this project's sensitivity config",
        malformed: "a path that cannot be read lexically"
      }.freeze
      REASONS = EXPLANATIONS.keys.freeze

      # Checked, not coerced, for the reason {Approval::Risk::Classification}
      # states: a wrong value answering the permissive question in silence is
      # exactly what this boundary must not do.
      #
      # Declared HERE, below {LEVELS}/{REASONS}, so both resolve by ordinary
      # lexical lookup -- {Project}'s reason. One declaration and not two guard
      # clauses, so a Verdict built with BOTH fields wrong reports both rather
      # than the first half of the mistake.
      declare do
        attribute :level
        attribute :reason
        validates :level, inclusion: { in: LEVELS, message: "must be one of #{LEVELS.join(", ")}, got %<value>p" }
        validates :reason, inclusion: { in: REASONS, message: "must be one of #{REASONS.join(", ")}, got %<value>p" }
      end

      def initialize(level:, reason:)
        self.class.check!(level:, reason:)

        super
      end

      def ordinary? = level == :ordinary
      def gated? = level == :gated
      def denied? = level == :denied
      def credential? = reason == :credential
      def exempt? = reason == :exempt
      def explanation = EXPLANATIONS.fetch(reason)
    end

    # The two directories a rule's `under` can be anchored on: the injected
    # home, and the project root a config names paths from. `root` is nil for
    # a classifier given none, which {Sensitivity#initialize} allows only while
    # no rule anchors there.
    Anchors = Data.define(:home, :root)

    Rule = Data.define(:level, :reason, :under, :inside, :name, :except, :exact, :anchor, :specimens)

    # One rule, as three independent locators, any of which may be absent:
    # `under` is an anchored subtree, `inside` is a directory name that must
    # appear somewhere on the way down, `name` is a basename glob, and `except`
    # takes a basename back. Every entry in both tables below is one of these, so
    # there is a single matcher to read rather than a family of them.
    #
    # `under` and `inside` are the two halves of the ruling on anchoring:
    # `inside` matches wherever it sits, which is right for `.ssh/id_*`, and
    # `under` is pinned to an anchor, which is right for `Cookies`. `anchor`
    # says which one: the home for the built-in tables, the project root for a
    # config pattern written with a leading `/`. `exact` narrows `under` from a
    # subtree to its one path, which is how a home-anchored exemption is split
    # in two (see {Sensitivity#initialize}). `specimens` are the basenames a
    # built-in entry is probed with when its own locators would name no file
    # anybody writes (see {#samples}).
    class Rule
      # Every rule here is about dotfiles, so a glob that could not match one
      # would be an elaborate way of matching nothing.
      GLOB = File::FNM_DOTMATCH
      # Braces in `except` only, where the built-in table takes back more than
      # one name. A config pattern never compiles an `except`, so its `{` stays
      # the literal it always was.
      EXCEPT_GLOB = GLOB | File::FNM_EXTGLOB
      HOME = :home
      ROOT = :root
      NO_SPECIMENS = [].freeze

      # `under: ""` anchors at the home directory itself, which is how the
      # browser names are kept out of a project checkout.
      def self.homed(under, level:, reason:, name: nil, except: nil, specimens: NO_SPECIMENS)
        new(level:, reason:, under:, inside: nil, name:, except:, specimens: specimens.freeze)
      end

      # A literal path under the project root: that one path when `exact`,
      # otherwise the directory and everything beneath it.
      def self.rooted(under, level:, reason:, exact:)
        new(level:, reason:, under:, inside: nil, name: nil, except: nil, exact:, anchor: ROOT)
      end

      def self.within(inside, level:, reason:, name: nil, except: nil)
        new(level:, reason:, under: nil, inside:, name:, except:)
      end

      def self.named(name, level:, reason:, except: nil)
        new(level:, reason:, under: nil, inside: nil, name:, except:)
      end

      # The basename a sample carries when the rule names none. A name no
      # config writes, so an exemption is never charged with lifting a
      # directory entry for sharing the placeholder's spelling.
      SAMPLE = "\u2400probe"
      STAR = "*"

      def initialize(level:, reason:, under:, inside:, name:, except:, exact: false, anchor: HOME,
                     specimens: NO_SPECIMENS)
        super
      end

      def homed? = !under.nil? && anchor == HOME
      def rooted? = !under.nil? && anchor == ROOT
      def credential? = reason == :credential

      # This rule at its anchored path only. A rule with no `under` has no
      # path to be exact about, so it is its own exact form.
      def exactly = under.nil? ? self : with(exact: true)

      # Whether this rule, as an exemption in the place {Sensitivity#initialize}
      # puts it, lifts `gated`: at its exact path it is consulted before every
      # built-in entry, beneath that only before the personal directories.
      #
      # @param gated [Rule] a built-in gated entry
      # @param anchors [Anchors] what both are anchored on
      def lifts?(gated, anchors)
        lifter = gated.credential? ? exactly : self
        gated.samples(anchors).any? { |sample| lifter.matches?(sample, anchors) }
      end

      def verdict = Verdict.new(level:, reason:)

      # @param path [String] already lexically normalized and home-rewritten
      # @param anchors [Anchors] the injected home and project root
      def matches?(path, anchors) = under?(path, anchors) && inside?(path) && named?(File.basename(path))

      # Paths this rule matches, so a question about what another rule would
      # LIFT can be asked without a filesystem to look in. A star matches the
      # empty string, so dropping each one gives the shortest name the glob
      # answers for -- the one a broad exemption is likeliest to catch. An
      # exact rule matches one path, so that path is its sample.
      #
      # Specimens win over both. A subtree with no name probes as the
      # placeholder, which no exemption matches, so `*_rsa` would lift the keys
      # under `~/.ssh` uncounted; and `config*` under `~/.kube` shortens to the
      # kubeconfig a denial judges first, so no exemption of a backup could be
      # counted against it.
      #
      # @param anchors [Anchors] what an anchored rule anchors on
      # @return [Array<String>]
      def samples(anchors)
        return [anchored(anchors)] if exact

        base = [under.nil? ? anchors.home : anchored(anchors), inside].compact
        (specimens.empty? ? [basename_sample] : specimens).map { |name| [*base, name].join(File::SEPARATOR) }
      end

      # How a refusal names this rule to the person who wrote the config.
      def label = [under && "#{prefix}#{under}".chomp(File::SEPARATOR), inside, name].compact.join(File::SEPARATOR)

      private

      def prefix = rooted? ? File::SEPARATOR : "~/"

      def basename_sample = name.nil? ? SAMPLE : name.delete(STAR)

      def under?(path, anchors)
        return true if under.nil?

        exact ? path == anchored(anchors) : descends?(path, anchored(anchors))
      end

      def anchored(anchors)
        base = rooted? ? anchors.root : anchors.home
        under.empty? ? base : "#{base.chomp(File::SEPARATOR)}/#{under}"
      end

      # The trailing separator is the whole guard: a bare `start_with?` would let
      # `/home/tester` swallow `/home/tester2`. Chomped first, because a project
      # root may be `/` itself where a home may not.
      def descends?(path, prefix) = path == prefix || path.start_with?("#{prefix.chomp(File::SEPARATOR)}/")

      # A whole SEGMENT of the path, so `.gnupg-backup` is not `.gnupg`, and any
      # segment rather than the immediate parent, so `~/.ssh/keys/id_rsa` is as
      # much a private key as `~/.ssh/id_rsa`. The last segment counts too: a
      # subtree rule that missed the subtree's own root would let a listing show
      # the directory while withholding everything inside it.
      def inside?(path) = inside.nil? || path.split(File::SEPARATOR).include?(inside)

      def named?(base) = called?(base) && !excepted?(base)

      def called?(base) = name.nil? || File.fnmatch?(name, base, GLOB)

      def excepted?(base) = !except.nil? && File.fnmatch?(except, base, EXCEPT_GLOB)
    end

    Rules = Data.define(:denied, :gated, :exempt)

    # The `[sensitivity]` table: what a project adds to the rules below, and the
    # one thing it may take away.
    #
    # Three keys, all lists of patterns. `denied` and `gated` ADD; `exempt`
    # subtracts, and subtracts from the gated half only -- a built-in denial is
    # matched first and nothing in this table is consulted. That is the whole
    # "may widen, may never narrow" rule, expressed as an ORDER rather than as a
    # check somebody has to remember to write.
    #
    # A pattern is a basename glob, a home-anchored path, or a path anchored at
    # the project root by its leading `/`, which is the one a committed config
    # can write wherever the checkout lives. Under `denied` and `gated` a
    # project path covers itself and everything beneath it, trailing `/` or
    # not: those keys restrict, so the spelling a person forgot must fail
    # closed, and a file has nothing beneath it to over-reach into. Under
    # `exempt` it names exactly one file, and a directory is refused -- by its
    # trailing `/` here, and by the disk where a loader can look
    # ({#exempting_files!}) -- because an exempted directory would lift every
    # credential inside it.
    #
    # What one exemption may lift is capped at ONE built-in gated entry, and
    # that is the whole guarantee: it stops a single broad glob (`.*`) from
    # turning a class off by accident. It is not a table-wide cap -- `*.key`
    # is one entry and still a class of files, and a config listing every
    # gated name on its own line lifts them all, deliberately, one line each.
    #
    #   [sensitivity]
    #   denied = ["*.secret", "/vault/"]
    #   gated  = ["*.private"]
    #   exempt = [".gitconfig", "/fixtures/.env"]
    #
    # `exempt` is a real key rather than a politely ignored one because
    # {Config::Answers} is right that an entry which can never do anything is
    # indistinguishable from one that was never written: a project whose
    # `.gitconfig` holds no credential has a legitimate reason to say so.
    class Rules
      # The constants live on this reopen rather than in a `Data.define` block,
      # where they would scope to {Sensitivity} instead (see
      # {Request::SYSTEM_PREFIX}).
      DENIED = "denied"
      GATED = "gated"
      EXEMPT = "exempt"
      KEYS = [DENIED, GATED, EXEMPT].freeze
      # What each key means as a verdict, and the reason it carries. A config
      # entry says so in its own reason, so a human reading a refusal can tell
      # our table from theirs.
      VERDICTS = { DENIED => %i[denied configured], GATED => %i[gated configured],
                   EXEMPT => %i[ordinary exempt] }.freeze
      HOME = "~/"
      ROOT = "/"
      SHAPES = %(a basename glob ("*.secret"), a home-anchored path ("~/.netrc") or a project-anchored path ("/vault/"))
      # Patterns that match every path there is. Legal where a key can only add.
      UNBOUNDED = ["*", "**", "~", HOME].freeze
      # An anchored pattern compiles to a LITERAL subtree matched against a
      # cleaned path, so a glob character, a `.` or `..` segment, or an empty
      # one names a directory no cleaned path ever has.
      GLOB_METACHARACTERS = /[*?\[{]/
      UNCLEAN_SEGMENTS = ["", ".", ".."].freeze
      LITERAL = "can never match: an anchored pattern is a literal, clean path -- no glob, no empty, " \
                "`.` or `..` segment"
      DIRECTORY = "names a directory, and an exemption lifts one file: a directory would lift every " \
                  "credential beneath it"
      # What an exemption is probed against. Any absolute path would do; the
      # samples and an anchored exemption only have to agree on one, and one
      # path for both anchors probes `/.env` exactly as it probes `~/.env`.
      PROBE_HOME = "/home/probe"
      PROBE = Anchors.new(home: PROBE_HOME, root: PROBE_HOME)
      WHOLESALE = "lifts %<count>d built-in gated entries (%<entries>s), and one exemption may lift at most " \
                  "one -- name each file or directory on its own line"

      # The table as `config.toml` spells it, which is how every refusal here
      # names it.
      TABLE = "[sensitivity]"

      # @param table [Object] whatever `raw["sensitivity"]` parsed to; nil when absent
      # @param path [String, nil] the config file, named in every refusal
      # @return [Rules]
      def self.from(table, path: nil)
        table = {} if table.nil?
        raise Config::Refusal.not_a_table(table, path:, table: TABLE) unless table.is_a?(Hash)

        unknown = table.keys - KEYS
        # A silently ignored `denide` reads as a rule that is in force and is not.
        raise Config::Refusal.unknown_keys(unknown, known: KEYS, path:, table: TABLE) unless unknown.empty?

        new(**KEYS.to_h { |key| [key.to_sym, compile(key, table.fetch(key, []), path:)] })
      end

      # @return [Rules] the value an absent table yields
      def self.empty = EMPTY

      # @raise [Config::Refusal]
      def self.compile(key, patterns, path: nil)
        raise not_a_list(key, patterns, path:) unless patterns.is_a?(Array)

        patterns.map { |pattern| rule(key, pattern, path:) }
      end

      # The patterns are frozen COPIES: they arrive from a TOML parse, so they
      # are mutable and the caller keeps them, and this value rides inside a
      # `Ractor.shareable?` {Sensitivity}. `dup.freeze` rather than `-@` for
      # {Risk::Keepsake.scalar}'s reason -- interning an unbounded config string
      # leaks it into the fstring table for the life of the process.
      def self.rule(key, pattern, path: nil)
        check!(key, pattern, path:)
        compiled = located(key, pattern, path:)
        lifted = key == EXEMPT ? lifted_by(compiled) : []
        raise malformed(key, pattern, wholesale(lifted), path:) if lifted.size > 1

        compiled
      end

      def self.located(key, pattern, path: nil)
        level, reason = VERDICTS.fetch(key)
        return Rule.homed(pattern.delete_prefix(HOME).freeze, level:, reason:) if pattern.start_with?(HOME)
        return rooted(key, pattern, level:, reason:, path:) if pattern.start_with?(ROOT)
        raise malformed(key, pattern, "is #{SHAPES}", path:) if pattern.include?("/")

        Rule.named(pattern.dup.freeze, level:, reason:)
      end

      def self.rooted(key, pattern, level:, reason:, path: nil)
        exemption = key == EXEMPT
        raise malformed(key, pattern, DIRECTORY, path:) if exemption && pattern.end_with?(ROOT)

        Rule.rooted(literal(pattern).freeze, level:, reason:, exact: exemption)
      end

      # The path between the anchor and a directory's trailing separator.
      def self.literal(pattern) = pattern.delete_prefix(ROOT).delete_suffix(ROOT)

      # The unbounded list caught `*` and missed `.*`, which ungated every
      # dot-named credential in one line. Enumerating spellings cannot close
      # that, so an exemption is judged by what it LIFTS, and more than one
      # built-in entry refuses. That caps one pattern; it caps nothing across
      # the table (see the class comment).
      def self.lifted_by(exemption)
        Sensitivity::GATED.select { |gated| exemption.lifts?(gated, PROBE) }
      end

      def self.wholesale(lifted)
        format(WHOLESALE, count: lifted.size, entries: lifted.map { |gated| gated.label.inspect }.join(", "))
      end

      # A pattern that survives compilation and then raises inside
      # `File.fnmatch?` breaks every LATER call rather than its own, so one line
      # in a committed config would crash the gate for good. Refused here, where
      # the refusal names the file.
      def self.check!(key, pattern, path: nil)
        raise malformed(key, pattern, "must be a string", path:) unless pattern.is_a?(String)
        raise malformed(key, pattern, "must be matchable text", path:) unless Sensitivity.readable?(pattern)
        raise malformed(key, pattern, "must not be blank", path:) if pattern.strip.empty?
        raise malformed(key, pattern, "matches everything", path:) if unbounded?(key, pattern)
        raise malformed(key, pattern, LITERAL, path:) if unmatchable_home?(pattern) || unmatchable_root?(pattern)
      end

      def self.unmatchable_home?(pattern)
        return false unless pattern.start_with?(HOME)

        unclean?(pattern.delete_prefix(HOME))
      end

      # A doubled separator is refused whole, because stripping the anchor and
      # the trailing separator from `//` would leave the root itself.
      def self.unmatchable_root?(pattern)
        return false unless pattern.start_with?(ROOT)

        pattern.include?("#{ROOT}#{ROOT}") || unclean?(literal(pattern))
      end

      def self.unclean?(subtree)
        subtree.match?(GLOB_METACHARACTERS) || subtree.split(File::SEPARATOR, -1).intersect?(UNCLEAN_SEGMENTS)
      end

      # `denied = "*.secret"` -- a single value where the shape is a list.
      #
      # @return [Config::Refusal]
      def self.not_a_list(key, patterns, path: nil)
        Config::Refusal.new("#{key} is a list of patterns, got #{patterns.class}",
                            path:, table: TABLE, key:, value: patterns)
      end

      # A pattern that can never match anything, which is the same failure as an
      # entry nobody wrote. `config/secrets/prod.key` lands here on purpose: a
      # path-shaped pattern with no anchor could mean from the root or from any
      # directory, and a reader of the config cannot tell which.
      #
      # @return [Config::Refusal]
      def self.malformed(key, pattern, detail, path: nil)
        Config::Refusal.new("#{key} #{detail}: #{pattern.inspect}", path:, table: TABLE, key:, value: pattern)
      end

      # `exempt` is the one key that SUBTRACTS, so a wildcard there is not a
      # widening: `exempt = ["*"]` turns the entire gated half off in one line,
      # and `exempt = ["~/"]` compiles to the whole home tree. The same patterns
      # under `denied` or `gated` can only ever add, so they stay legal.
      def self.unbounded?(key, pattern) = key == EXEMPT && UNBOUNDED.include?(pattern)

      private_class_method :compile, :rule, :located, :rooted, :literal, :lifted_by, :wholesale, :check!, :unbounded?,
                           :unmatchable_home?, :unmatchable_root?, :unclean?, :not_a_list

      # Validated in the constructor too, {Config::Answers}' precedent: a value
      # built by hand carries rules that never came through {.from}.
      def initialize(denied: [], gated: [], exempt: [])
        super(denied: settled(DENIED, denied), gated: settled(GATED, gated), exempt: settled(EXEMPT, exempt))
      end

      # Whether any pattern here needs a project root to mean anything.
      def rooted? = [*denied, *gated, *exempt].any?(&:rooted?)

      # The half of the directory refusal this table cannot make itself: it
      # makes no syscall, so whether `/fixtures` is a directory is the loader's
      # to answer.
      #
      # @param directory [#call] `anchored path -> Boolean`, relative to the root
      # @param path [String, nil] the config file, named in the refusal
      # @return [Rules] self
      # @raise [Config::Refusal] naming the first exemption that is a directory
      def exempting_files!(directory, path: nil)
        found = exempt.select(&:rooted?).find { |rule| directory.call(rule.under) }
        raise self.class.malformed(EXEMPT, found.label, DIRECTORY, path:) if found

        self
      end

      private

      # Re-frozen rather than stored as handed over: the caller's Array is theirs
      # to keep mutating, and this value rides inside a frozen {Sensitivity}.
      def settled(key, rules)
        rules.map { |rule| rule.is_a?(Rule) ? rule : self.class.send(:rule, key, rule) }.freeze
      end

      EMPTY = new.freeze
      private_constant :EMPTY
    end

    # Off limits: not approvable, not liftable, so each entry is as narrow as it
    # can be while still naming the whole secret.
    DENIED = [
      # Unambiguous. Matched wherever they sit, because an absolute path into
      # another user's home -- `/root/.ssh/id_rsa`, a mounted backup -- is still
      # a private key, and a home-anchored table only ever saw one home.
      Rule.within(".ssh", name: "id_*", except: "*.pub", level: :denied, reason: :protected),
      Rule.within(".gnupg", level: :denied, reason: :protected),
      Rule.within(".aws", name: "credentials", level: :denied, reason: :protected),
      Rule.within(".password-store", level: :denied, reason: :protected),
      Rule.named(".netrc", level: :denied, reason: :protected),
      Rule.named("*.kdbx", level: :denied, reason: :protected),
      # Ambiguous, so anchored under home: `config`, `config.json`, `Cookies`
      # and `key4.db` are all plausible names in a checkout, and every profile
      # layout holding these puts them under `$HOME`.
      Rule.homed(".config/gh/hosts.yml", level: :denied, reason: :protected),
      Rule.homed(".docker/config.json", level: :denied, reason: :protected),
      Rule.homed(".kube/config", level: :denied, reason: :protected),
      Rule.homed("", name: "Cookies", level: :denied, reason: :protected),
      Rule.homed("", name: "Login Data", level: :denied, reason: :protected),
      Rule.homed("", name: "key4.db", level: :denied, reason: :protected)
    ].freeze

    # Worth asking about. A spurious match here costs one prompt, so these are
    # the half that widens.
    #
    # It was sized for a world where a human is still asked, and an automatic
    # approver asks nobody: `cat config/master.key`, `.pgpass`, a shell history
    # and a bare `id_rsa` were each released verbatim by one. `*.key` is what
    # covers Rails' `config/master.key`, so there is no second entry for it.
    #
    # Names match case-SENSITIVELY. On Linux `server.KEY` is a different file,
    # but a toolchain that writes `.KEY` or `.PEM` still wrote a key, and on a
    # case-insensitive filesystem `CONFIG/MASTER.KEY` opens the lowercase one.
    # Those spellings are ordinary here today.
    GATED = [
      *%w[.env .env.* .envrc *.pem *.p12 *.key *.keyring credentials.json credentials.yml.enc secrets.y*ml
          .git-credentials .npmrc .pypirc .pgpass .gitconfig rclone.conf terraform.tfstate *.tfvars *_history
          .vault-token application_default_credentials.json]
        .map { |name| Rule.named(name, level: :gated, reason: :credential) },
      # A private key copied out of `.ssh`, which is where the DENIED rule
      # reaches. Gated rather than denied because outside `.ssh` the name is
      # ambiguous enough that a denial nobody can lift would be the wrong error.
      *%w[id_rsa* id_dsa* id_ed25519* id_ecdsa*]
        .map { |name| Rule.named(name, except: "*.pub", level: :gated, reason: :credential) },
      Rule.within(".gem", name: "credentials", level: :gated, reason: :credential),
      Rule.within(".cargo", name: "credentials.toml", level: :gated, reason: :credential),
      Rule.within(".terraform.d", name: "credentials.tfrc.json", level: :gated, reason: :credential),
      Rule.within(".ssh", name: "config", level: :gated, reason: :credential),
      Rule.within("keyrings", level: :gated, reason: :credential),
      # A key in `~/.ssh` need not be called `id_*`, which is all the denial
      # can name. Everything there but public keys and `known_hosts` is asked
      # about, the directory itself included.
      # One specimen per key type the `id_*` rows name, so a glob over any of
      # them is counted against the keys kept here under other names.
      Rule.homed(".ssh", except: "{*.pub,known_hosts}", level: :gated, reason: :credential,
                         specimens: %w[github_rsa github_dsa github_ecdsa github_ed25519]),
      Rule.homed(".azure", specimens: %w[msal_token_cache.json], level: :gated, reason: :credential),
      # The kubeconfig itself is denied, and a backup beside it is not the file
      # the denial names while holding the same cluster credentials.
      Rule.homed(".kube", name: "config*", specimens: %w[config.bak], level: :gated, reason: :credential),
      *%w[Downloads Documents Desktop Pictures]
        .map { |dir| Rule.homed(dir, level: :gated, reason: :out_of_scope) },
      # The process filesystem, and these two files only. MEASURED, not
      # reasoned about: a child spawned the way this codebase spawns one
      # inherits the session's `ANTHROPIC_API_KEY`, because {Exec.child_env}
      # scrubs `FRAMEWORK_ENV` -- bundler and rspec variables -- and nothing
      # else. A canary key set on the session was read straight back out of the
      # child's own `/proc/self/environ`. So this is a live credential read
      # rather than a theoretical one, and `credential` is its true reason.
      #
      # `cmdline` is here on its own measurement: it is mode 444 and owned by
      # the reader, so a same-user process invoked with `--api-key=...` hands
      # its whole argv to anything that opens it -- verified on this box with a
      # canary argument. Lain deliberately keeps its own key OFF argv
      # (`up.rb`, `pane_command.rb`, `docker.rb` all say so), so what this
      # guards is the OTHER processes a session can see, not one of ours.
      #
      # GATED and not DENIED, on this tier's own criterion: someone debugging
      # their own process may legitimately read an environ, and being wrong
      # costs one prompt. Nothing here claims all of `/proc` is off limits --
      # `maps` leaks address-space layout rather than credentials and is
      # deliberately untouched, because no tier moves on an unmeasured argument.
      #
      # {Rule.within} matches a `proc` SEGMENT anywhere, so `vendor/proc/environ`
      # in a checkout is gated too. Over-broad, failing closed, one prompt --
      # which is the bargain this whole half of the table is written on.
      *%w[environ cmdline]
        .map { |name| Rule.within("proc", name:, level: :gated, reason: :credential) },
      # A repository's own config, which routinely carries a token inside a
      # remote URL (`https://x-access-token:TOKEN@host/...`). `.gitconfig` was
      # already gated for that shape and this was not, which was an asymmetry in
      # the table rather than a considered position. Anchored on the `.git`
      # SEGMENT, on {Rule.within}'s shape, because a bare `config` basename is a
      # plausible name in any checkout.
      Rule.within(".git", name: "config", level: :gated, reason: :credential)
    ].freeze

    # The Null Object at the end of the chain, so no caller and no branch here
    # asks whether a rule was found.
    ORDINARY = Rule.new(level: :ordinary, reason: :none, under: nil, inside: nil, name: nil, except: nil)

    # GATED split by what a home-anchored exemption may reach beneath its path.
    CREDENTIALS, PERSONAL = GATED.partition(&:credential?).map(&:freeze)

    # A path this classifier cannot read. GATED and not ordinary: gated reaches
    # a human and is liftable, which is the right posture for input nobody can
    # parse, and {Approval::Risk#reasons_for} calls the same input class risky
    # for the same reason.
    MALFORMED = Verdict.new(level: :gated, reason: :malformed)

    ROOT = "/"
    TILDE = "~"
    NUL = "\0"
    # A leading `~`, `~/` or `~someone/`. Rewritten to the INJECTED home by pure
    # string substitution -- never `File.expand_path`, which resolves a named
    # tilde through getpwnam and is a socket to nscd on an SSSD or LDAP-backed
    # host (`risk.rb:212-220`). Another user's `~/.ssh/id_rsa` is unambiguously
    # a secret, so treating every tilde as home widens in the safe direction.
    TILDE_SEGMENT = %r{\A~[^/]*(?=/|\z)}

    # The two inputs that get past a String check and then raise: a NUL byte
    # (`ArgumentError` out of `Pathname#cleanpath` and `File.fnmatch?`) and a
    # non-ASCII-compatible encoding (`Encoding::CompatibilityError`, which is NOT
    # an ArgumentError, so no rescue would catch it). {Approval::Risk#readable?}
    # tests the same pair, and the `&&` order matters: `include?` on a UTF-16
    # String raises the very error being tested for.
    def self.readable?(text)
      text.encoding.ascii_compatible? && text.valid_encoding? && !text.include?(NUL)
    end

    # A home of "" (HOME unset) or "/" (Docker's default when the uid has no
    # /etc/passwd entry) builds prefixes like "//.ssh" that match nothing,
    # silently disabling every home-anchored rule below. A cwd of "/" is fine,
    # so only `home` is declared.
    #
    # Judged on the ANCHORED path rather than the argument as written, exactly
    # as the guard clause it replaces was -- which is also why the message now
    # reports the anchored form: `"/./"` and `"/"` are one home, and saying so
    # is the more useful of the two answers.
    declare do
      attribute :home
      validates :home, exclusion: { in: [ROOT], message: "must not be the filesystem root, got %<value>p" }
    end

    # @param home [String, Pathname] the user's home directory, INJECTED -- never read from ENV here
    # @param cwd [String, Pathname] what a relative path resolves against, also injected
    # The order is the precedence. A home-anchored exemption appears TWICE:
    # exactly at its path before every built-in gated entry, so `~/.gitconfig`
    # lifts that file, and as a subtree after the credential entries but before
    # the personal directories, so `~/Downloads` opens the directory while
    # `~/Downloads/.env` and `~/src/app/config/master.key` still gate. A
    # project-anchored exemption is one file, so it appears only the first time.
    #
    # @param rules [Rules] what this project added, and what it exempted
    # @param root [String, Pathname, nil] the project root a `/`-anchored
    #   pattern is read from. Optional only while `rules` anchors nothing
    #   there: a denial anchored on no root would match nothing, in silence.
    def initialize(home:, cwd:, rules: Rules.empty, root: nil)
      @home = anchor(:home, home)
      @cwd = anchor(:cwd, cwd)
      self.class.check!(home: @home)
      @anchors = Anchors.new(home: @home, root: project_root(root, rules))

      @rules = [*DENIED, *rules.denied, *rules.exempt.map(&:exactly), *CREDENTIALS, *rules.exempt.select(&:homed?),
                *PERSONAL, *rules.gated, ORDINARY].freeze
      freeze
    end

    # @param path [String, Pathname] a path as it was written, not as it resolves
    # @return [Verdict] never nil
    # @raise [ArgumentError] when `path` is not path-shaped at all -- see {#text!}
    def classify(path) = verdict_for(text!(path))

    def denied?(path) = classify(path).denied?
    def gated?(path) = classify(path).gated?

    private

    # The line this class draws, and it has two sides. A wrong TYPE is the
    # caller's bug and is loud. Malformed BYTES are hostile data and fail closed
    # at {MALFORMED}. `path.to_s` used to erase the difference and answer
    # `:ordinary` for both, which is fail-OPEN on a type error.
    def text!(path)
      text(path) || raise(ArgumentError, "a path must be a String or a Pathname, got #{path.inspect}")
    end

    def text(value)
      return value if value.is_a?(String)

      converted = value.respond_to?(:to_path) ? value.to_path : nil
      converted.is_a?(String) ? converted : nil
    end

    def verdict_for(path)
      return MALFORMED unless Sensitivity.readable?(path)

      clean = lexical(path)

      @rules.find { |rule| rule.matches?(clean, @anchors) }.verdict
    rescue ArgumentError, EncodingError
      # Defence in depth, {Approval::Risk::OutsideRoot}'s posture: `readable?`
      # takes the two inputs we know of, and unresolvable is exactly the case
      # that must not be waved through.
      MALFORMED
    end

    def project_root(root, rules)
      return anchor(:root, root) unless root.nil?
      raise ArgumentError, "root is required: this project's [sensitivity] table anchors a pattern on it" \
        if rules.rooted?

      nil
    end

    # An anchor that is not absolute cannot anchor anything, so it is refused
    # rather than quietly producing a table that matches nothing.
    def anchor(name, value)
      given = text(value)
      raise ArgumentError, "#{name} must be an absolute path, got #{value.inspect}" \
        unless given&.start_with?(ROOT) && Sensitivity.readable?(given)

      # Cleaned directly rather than through {#lexical}, which reads `@cwd` --
      # not yet set while this is anchoring `home`.
      Pathname.new(given).cleanpath.to_s.dup.freeze
    end

    # `Pathname#cleanpath` and not `File.expand_path`: it folds `.` and `..`
    # with pure string work, leaves a leading `~` alone, and consults neither the
    # filesystem nor `Dir.pwd`.
    def lexical(path) = Pathname.new(rooted(path)).cleanpath.to_s

    # Two rewrites, both pure string work: a leading tilde becomes the injected
    # home ({TILDE_SEGMENT}), and anything still relative resolves against the
    # injected cwd. {Approval::Escalation::Triage} classifies bash argv, where
    # relative is the norm, and leaving each caller to normalize first would be
    # three copies of one rule -- the drift this chunk exists to prevent. Nothing
    # is expanded, nothing stat'ed.
    def rooted(path)
      return path.sub(TILDE_SEGMENT) { @home } if path.start_with?(TILDE)
      return path if path.start_with?(ROOT)

      "#{@cwd}/#{path}"
    end
  end
end
