# frozen_string_literal: true

require "pathname"

module Lain
  # Is this path ordinary, worth a gate, or off limits entirely -- decided from
  # the NAME alone.
  #
  # Every arm of the secret boundary needs this answer, and several of them need
  # it before the file is opened: {Effect::Handler::Sensitivity} refuses a denied
  # read before any approval, {Sensitivity::Policy} decides whether a tool call
  # reaches a human, and {Approval::Escalation::Triage} reads it off a parsed
  # argv. So the classifier does no IO at all -- no `stat`, no `realpath`, no
  # entropy over the bytes -- and is free to call from any of them, in any order,
  # as often as they like.
  #
  # == Lexical, and that is a decision
  #
  # A symlink named `notes.md` pointing at `~/.ssh/id_ed25519` classifies
  # ordinary. {Approval::Risk::OutsideRoot} (`risk.rb:192-232`) already chose
  # lexical matching so it agrees with {Workspace::Restore} about what "outside
  # the root" means, and resolving links here would both disagree with that and
  # put a syscall in a classifier whose whole contract is that it makes none. The
  # hole has a name and a spec rather than a stat.
  #
  # == A path is rewritten before it is matched, and only with string work
  #
  # Three steps, in order, none of them touching the filesystem. A leading tilde
  # segment -- `~`, `~/` or even `~someone/` -- is replaced by the INJECTED home
  # ({TILDE_SEGMENT}); anything still relative is joined to the INJECTED cwd; and
  # the result goes through `Pathname#cleanpath`, which folds `.` and `..`
  # lexically. So `~root/.netrc` and `~someone/.ssh/id_rsa` ARE home-anchored and
  # both deny.
  #
  # Nothing is ever handed to `File.expand_path`, and a named tilde is emphatically
  # not resolved through getpwnam: on an SSSD or LDAP-backed host that is a socket
  # to nscd, i.e. a network call from a classifier whose contract is that it makes
  # none (`risk.rb:212-220`). Rewriting every tilde to OUR home rather than
  # resolving whose it is loses nothing worth having -- another user's
  # `~/.ssh/id_rsa` is a private key by anybody's reckoning.
  #
  # == Which direction each half errs in, and where each rule is anchored
  #
  # {Approval::Risk}'s rule -- widen, never sharpen (`risk.rb:66-72`) -- applies
  # to the GATED half only, where a spurious match costs one prompt. The DENIED
  # half is the opposite: no policy, no `--yolo` and no `ApproveAll` lifts a
  # denial, so a false positive there makes a file permanently unreadable with no
  # move available to anyone. That is why `id_*` carries a `*.pub` exception.
  #
  # It is also why the denied table is split by how AMBIGUOUS a name is, rather
  # than by where the secret usually lives, and the split is roughly even:
  #
  # - Unambiguous, so matched ANYWHERE (`inside`/`name`): `.ssh/id_*`,
  #   `.gnupg`, `.aws/credentials`, `.password-store`, `.netrc`, `*.kdbx`. An
  #   absolute path into another user's home or a mounted backup is still a
  #   private key, and a home-anchored table only ever sees ONE home.
  # - Ambiguous, so anchored UNDER THE INJECTED HOME (`under`): `Cookies`,
  #   `Login Data`, `key4.db`, `.kube/config`, `.docker/config.json`,
  #   `.config/gh/hosts.yml`. Every profile layout holding these puts them under
  #   `$HOME`, and `config` or `Cookies` is a plausible name in a checkout.
  #
  # The anchored ones match a whole path SEGMENT, so `/home/tester` never
  # swallows `/home/tester2`.
  class Sensitivity
    Verdict = Data.define(:level, :reason)

    # What the classifier answers. Frozen and shareable by being a Data of
    # Symbols, so it journals and crosses a Ractor as-is.
    class Verdict
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
      def initialize(level:, reason:)
        raise ArgumentError, "level must be one of #{LEVELS.join(", ")}, got #{level.inspect}" \
          unless LEVELS.include?(level)
        raise ArgumentError, "reason must be one of #{REASONS.join(", ")}, got #{reason.inspect}" \
          unless REASONS.include?(reason)

        super
      end

      def ordinary? = level == :ordinary
      def gated? = level == :gated
      def denied? = level == :denied
      def credential? = reason == :credential
      def explanation = EXPLANATIONS.fetch(reason)
    end

    Rule = Data.define(:level, :reason, :under, :inside, :name, :except)

    # One rule, as three independent locators, any of which may be absent:
    # `under` is a home-anchored subtree, `inside` is a directory name that must
    # appear somewhere on the way down, `name` is a basename glob, and `except`
    # takes a basename back. Every entry in both tables below is one of these, so
    # there is a single matcher to read rather than a family of them.
    #
    # `under` and `inside` are the two halves of the ruling on anchoring:
    # `inside` matches wherever it sits, which is right for `.ssh/id_*`, and
    # `under` is pinned to the injected home, which is right for `Cookies`.
    class Rule
      # Every rule here is about dotfiles, so a glob that could not match one
      # would be an elaborate way of matching nothing.
      GLOB = File::FNM_DOTMATCH

      # `under: ""` anchors at the home directory itself, which is how the
      # browser names are kept out of a project checkout.
      def self.homed(under, level:, reason:, name: nil, except: nil)
        new(level:, reason:, under:, inside: nil, name:, except:)
      end

      def self.within(inside, level:, reason:, name: nil, except: nil)
        new(level:, reason:, under: nil, inside:, name:, except:)
      end

      def self.named(name, level:, reason:, except: nil)
        new(level:, reason:, under: nil, inside: nil, name:, except:)
      end

      def verdict = Verdict.new(level:, reason:)

      # @param path [String] already lexically normalized and home-rewritten
      # @param home [String] the injected home
      def matches?(path, home) = under?(path, home) && inside?(path) && named?(File.basename(path))

      private

      def under?(path, home) = under.nil? || descends?(path, anchored(home))

      def anchored(home) = under.empty? ? home : "#{home}/#{under}"

      def descends?(path, prefix) = path == prefix || path.start_with?("#{prefix}/")

      # A whole SEGMENT of the path, so `.gnupg-backup` is not `.gnupg`, and any
      # segment rather than the immediate parent, so `~/.ssh/keys/id_rsa` is as
      # much a private key as `~/.ssh/id_rsa`. The last segment counts too: a
      # subtree rule that missed the subtree's own root would let T19 list the
      # directory while withholding everything inside it.
      def inside?(path) = inside.nil? || path.split(File::SEPARATOR).include?(inside)

      def named?(base) = called?(base) && !excepted?(base)

      def called?(base) = name.nil? || File.fnmatch?(name, base, GLOB)

      def excepted?(base) = !except.nil? && File.fnmatch?(except, base, GLOB)
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
    #   [sensitivity]
    #   denied = ["*.secret"]
    #   gated  = ["*.private"]
    #   exempt = [".gitconfig"]
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
      SHAPES = %(a basename glob ("*.secret") or a home-anchored path ("~/.netrc"))
      # Patterns that match every path there is. Legal where a key can only add.
      UNBOUNDED = ["*", "**", "~", HOME].freeze

      # {Config::Answers::Refusal}'s posture: a path that may be absent in front
      # of a detail naming the table it came from.
      class Refusal < Error
        attr_reader :path

        def initialize(path, detail)
          @path = path
          prefix = path ? "#{path}: " : ""
          super("#{prefix}#{detail}")
        end
      end

      # `sensitivity = "strict"` -- the sibling of {Config::Answers::NotATable}.
      class NotATable < Refusal
        attr_reader :value

        def initialize(value, path: nil)
          @value = value
          super(path, "[sensitivity] must be a table, got #{value.class}: #{value.inspect}")
        end
      end

      # A typo for one of the three strengths. Loud rather than dropped: a
      # silently ignored `denide` reads as a rule that is in force and is not.
      class UnknownKeys < Refusal
        attr_reader :keys

        def initialize(keys, path: nil)
          @keys = keys
          super(path, "[sensitivity] has no keys #{keys.map(&:inspect).join(", ")}; known keys: #{KEYS.join(", ")}")
        end
      end

      # `denied = "*.secret"` -- a single value where the shape is a list.
      class NotAList < Refusal
        attr_reader :key, :value

        def initialize(key, value, path: nil)
          @key = key
          @value = value
          super(path, "[sensitivity] #{key} is a list of patterns, got #{value.class}")
        end
      end

      # A pattern that can never match anything, which is the same failure as an
      # entry nobody wrote. `config/secrets/prod.key` lands here on purpose: a
      # path-shaped pattern with no anchor has no defined meaning yet, and
      # refusing it now is what leaves room to define one later.
      class MalformedPattern < Refusal
        attr_reader :key, :pattern

        def initialize(key, pattern, detail, path: nil)
          @key = key
          @pattern = pattern
          super(path, "[sensitivity] #{key} #{detail}: #{pattern.inspect}")
        end
      end

      # @param table [Object] whatever `raw["sensitivity"]` parsed to; nil when absent
      # @param path [String, nil] the config file, named in every refusal
      # @return [Rules]
      def self.from(table, path: nil)
        table = {} if table.nil?
        raise NotATable.new(table, path:) unless table.is_a?(Hash)

        unknown = table.keys - KEYS
        raise UnknownKeys.new(unknown, path:) unless unknown.empty?

        new(**KEYS.to_h { |key| [key.to_sym, compile(key, table.fetch(key, []), path:)] })
      end

      # @return [Rules] the value an absent table yields
      def self.empty = EMPTY

      # @raise [NotAList, MalformedPattern]
      def self.compile(key, patterns, path: nil)
        raise NotAList.new(key, patterns, path:) unless patterns.is_a?(Array)

        patterns.map { |pattern| rule(key, pattern, path:) }
      end

      # The patterns are frozen COPIES: they arrive from a TOML parse, so they
      # are mutable and the caller keeps them, and this value rides inside a
      # `Ractor.shareable?` {Sensitivity}. `dup.freeze` rather than `-@` for
      # {Risk::Keepsake.scalar}'s reason -- interning an unbounded config string
      # leaks it into the fstring table for the life of the process.
      def self.rule(key, pattern, path: nil)
        check!(key, pattern, path:)
        level, reason = VERDICTS.fetch(key)
        return Rule.homed(pattern.delete_prefix(HOME).freeze, level:, reason:) if pattern.start_with?(HOME)
        raise MalformedPattern.new(key, pattern, "is #{SHAPES}", path:) if pattern.include?("/")

        Rule.named(pattern.dup.freeze, level:, reason:)
      end

      # A pattern that survives compilation and then raises inside
      # `File.fnmatch?` breaks every LATER call rather than its own, so one line
      # in a committed config would crash the gate for good. Refused here, where
      # the refusal names the file.
      def self.check!(key, pattern, path: nil)
        raise MalformedPattern.new(key, pattern, "must be a string", path:) unless pattern.is_a?(String)
        raise MalformedPattern.new(key, pattern, "must be matchable text", path:) unless Sensitivity.readable?(pattern)
        raise MalformedPattern.new(key, pattern, "must not be blank", path:) if pattern.strip.empty?
        raise MalformedPattern.new(key, pattern, "matches everything", path:) if unbounded?(key, pattern)
      end

      # `exempt` is the one key that SUBTRACTS, so a wildcard there is not a
      # widening: `exempt = ["*"]` turns the entire gated half off in one line,
      # and `exempt = ["~/"]` compiles to the whole home tree. The same patterns
      # under `denied` or `gated` can only ever add, so they stay legal.
      def self.unbounded?(key, pattern) = key == EXEMPT && UNBOUNDED.include?(pattern)

      private_class_method :compile, :rule, :check!, :unbounded?

      # Validated in the constructor too, {Config::Answers}' precedent: a value
      # built by hand carries rules that never came through {.from}.
      def initialize(denied: [], gated: [], exempt: [])
        super(denied: settled(DENIED, denied), gated: settled(GATED, gated), exempt: settled(EXEMPT, exempt))
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
    # can be while still naming the whole secret. The split is by AMBIGUITY of
    # the name, not by where the secret usually lives.
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
      # Ambiguous, so anchored under home. `config`, `config.json`, `Cookies`
      # and `key4.db` are all plausible names in a checkout, and a denial cannot
      # be lifted by any policy, `--yolo` or `ApproveAll` -- so a false positive
      # here makes a source file permanently unreadable with no move available.
      Rule.homed(".config/gh/hosts.yml", level: :denied, reason: :protected),
      Rule.homed(".docker/config.json", level: :denied, reason: :protected),
      Rule.homed(".kube/config", level: :denied, reason: :protected),
      Rule.homed("", name: "Cookies", level: :denied, reason: :protected),
      Rule.homed("", name: "Login Data", level: :denied, reason: :protected),
      Rule.homed("", name: "key4.db", level: :denied, reason: :protected)
    ].freeze

    # Worth asking about. A spurious match here costs one prompt, so these are
    # the half that widens.
    GATED = [
      *%w[.env .env.* .envrc *.pem *.p12 credentials.json secrets.y*ml .git-credentials
          .npmrc .pypirc .gitconfig terraform.tfstate *.tfvars]
        .map { |name| Rule.named(name, level: :gated, reason: :credential) },
      *%w[Downloads Documents Desktop Pictures]
        .map { |dir| Rule.homed(dir, level: :gated, reason: :out_of_scope) }
    ].freeze

    # The Null Object at the end of the chain, so no caller and no branch here
    # asks whether a rule was found.
    ORDINARY = Rule.new(level: :ordinary, reason: :none, under: nil, inside: nil, name: nil, except: nil)

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

    # @param home [String, Pathname] the user's home directory, INJECTED -- never read from ENV here
    # @param cwd [String, Pathname] what a relative path resolves against, also injected
    # @param rules [Rules] what this project added, and what it exempted
    def initialize(home:, cwd:, rules: Rules.empty)
      @home = anchor(:home, home)
      @cwd = anchor(:cwd, cwd)
      # A home of "" (HOME unset) or "/" (Docker's default when the uid has no
      # /etc/passwd entry) builds prefixes like "//.ssh" that match nothing,
      # silently disabling every home-anchored rule below. A cwd of "/" is fine.
      raise ArgumentError, "home must not be the filesystem root, got #{home.inspect}" if @home == ROOT

      @rules = [*DENIED, *rules.denied, *rules.exempt, *GATED, *rules.gated, ORDINARY].freeze
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

      @rules.find { |rule| rule.matches?(clean, @home) }.verdict
    rescue ArgumentError, EncodingError
      # Defence in depth, {Approval::Risk::OutsideRoot}'s posture: `readable?`
      # takes the two inputs we know of, and unresolvable is exactly the case
      # that must not be waved through.
      MALFORMED
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
    # injected cwd. T20 classifies bash argv, where relative is the norm, and
    # leaving each caller to normalize first would be three copies of one rule --
    # the drift this chunk exists to prevent. Nothing is expanded, nothing stat'ed.
    def rooted(path)
      return path.sub(TILDE_SEGMENT) { @home } if path.start_with?(TILDE)
      return path if path.start_with?(ROOT)

      "#{@cwd}/#{path}"
    end
  end
end

# Policy and Regions both reopen Sensitivity, so the class body must load first.
require_relative "sensitivity/policy"
require_relative "sensitivity/regions"
