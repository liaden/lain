# frozen_string_literal: true

require "tomlrb"

module Lain
  # Reads `<root>/.lain/config.toml`. Absence is not an error -- {.load} on a
  # root with no file returns the same value {.empty} does, so a caller never
  # writes an `if File.exist?` guard of its own (Null Object).
  #
  # `[epics]` and `[approval]` are understood. Every OTHER top-level table is
  # tolerated and ignored: other consumers are coming (chat-ux's prompt config
  # may converge on this same file later), and a table this class doesn't yet
  # read is not this class's typo to catch. Each table it DOES read is one
  # small class's whole surface -- {Epics}, {Answers} -- so a typo or a
  # wrong-shaped value inside one is loud instead of silently defaulting or
  # crashing three call frames deep.
  class Config
    # Named per the error-taxonomy convention: a refusal subclasses
    # {Lain::Error} next to the owner that raises it (see {Paths::Unwritable}).
    # `path`/`cause` default to nil so a bare `raise Config::Malformed` -- a
    # caller re-raising without the specifics -- does not itself blow up with
    # a mismatched-arity ArgumentError; the wrapped parse error still arrives
    # through Ruby's own `Exception#cause` chaining (set automatically because
    # this is raised from inside the rescue that caught it), so it is never
    # duplicated onto a second reader here.
    class Malformed < Error
      attr_reader :path

      def initialize(path = nil, cause = nil)
        @path = path
        super(describe(path, cause))
      end

      private

      # Only a genuine `Tomlrb::ParseError` means the file was actually
      # handed to the parser and rejected -- "is not valid TOML" is true only
      # then. `ArgumentError` (bad encoding) and `SystemCallError`
      # (EACCES/EISDIR and siblings) all mean the file was never successfully
      # READ in the first place, so claiming it is "not valid TOML" would be
      # a lie about what happened, however loud and well-pathed the message.
      def describe(path, cause)
        return "config.toml is malformed" unless path && cause

        reason = cause.is_a?(Tomlrb::ParseError) ? "is not valid TOML" : "could not be read as TOML"
        "#{path} #{reason}: #{cause.message}#{bom_hint(cause)}"
      end

      # tomlrb's lexer does not strip a leading UTF-8 BOM; it reports the mark
      # itself as an unparseable value. An editor put it there, not the
      # author, so the hint names it instead of leaving a raw "parse error on
      # value ..." to puzzle over.
      def bom_hint(cause)
        cause.message.include?("﻿") ? " (starts with a UTF-8 BOM -- strip it)" : ""
      end
    end

    # The `[epics]` table, its own collaborator rather than a private method
    # on {Config}: other top-level tables are coming (chat-ux's prompt config
    # may converge on this file), and each one earns exactly this shape --
    # one small class that knows its own keys, its own allowed values, and
    # raises its own named errors -- rather than {Config} accreting another
    # `*_from` method and two more error classes per table it learns to read.
    #
    # The TOML key is `home` (`[epics]` / `home = "repo"`); the Ruby reader
    # stays `#epics_home`. `[epics] epics_home` would stutter
    # (`epics.epics_home`), and the typo this class's own AC teaches
    # ("hoem") is a typo of "home", not of "epics_home".
    Epics = Data.define(:home, :gates)

    class Epics
      # Reopened (not a body inside the `Data.define do ... end` block) because
      # constants and nested classes defined THERE are lexically scoped to
      # `Lain::Config`, not to `Epics` itself -- a documented trap, see
      # `Request::SYSTEM_PREFIX` for the precedent.
      HOME_VALUES = %w[xdg repo].freeze
      KEYS = %w[home gates].freeze

      # `[epics]` present but not a table -- TOML permits a scalar or an array
      # there (`epics = "x"`), and treating it as one without checking crashes
      # on the first `.keys` call with an unnamed NoMethodError.
      class NotATable < Error
        attr_reader :path, :value

        def initialize(value, path:)
          @path = path
          @value = value
          super("#{path}: [epics] must be a table, got #{value.class}: #{value.inspect}")
        end
      end

      # A typo inside `[epics]` -- that table is this class's whole surface,
      # so an unrecognized key is loud rather than silently ignored the way
      # an unknown top-level table is. Plural because `.from` reports every
      # unknown key in one pass, not just the first.
      class UnknownKeys < Error
        attr_reader :path, :keys

        def initialize(keys, path:)
          @path = path
          @keys = keys
          super("#{path}: [epics] has no keys #{keys.map(&:inspect).join(", ")}; known keys: #{KEYS.join(", ")}")
        end
      end

      # `home` set to anything other than the strings "xdg" or "repo" --
      # including a value of the wrong TYPE (an Integer, a Boolean, an Array):
      # membership is checked against the two allowed STRINGS directly, so a
      # foreign type simply fails the `include?` and is named here, rather
      # than being coerced first and crashing inside `#to_sym`. `path:`
      # defaults to nil because {Epics#initialize} also raises this -- a
      # value constructed directly (not through `.from`) carries no config
      # file to name.
      class InvalidHome < Error
        attr_reader :path, :value

        def initialize(value, path: nil)
          @path = path
          @value = value
          prefix = path ? "#{path}: " : ""
          super("#{prefix}epics_home #{value.inspect} is not one of #{HOME_VALUES.join(", ")}")
        end
      end

      # The `[epics.gates]` sub-table: which {Approval::Gate::Policy} each epic
      # stage's gates run under (`epic_plan = "deferred"`). Its own small class
      # for {Epics}'s own reason -- it knows its keys, its allowed values, and
      # its errors -- and BOTH sides of the mapping are closed sets, so both are
      # refused at load rather than discovered at the first overnight gate.
      #
      # The allowed VALUES are not spelled here: {Approval::Gate::Policies.known?}
      # answers, so widening the policy family is one edit in the factory rather
      # than two that can disagree. That reference is resolved at CALL time,
      # which is why it does not invert lain.rb's load order.
      #
      # Absence means interactive everywhere, so {#policy_for} is total: a stage
      # nobody configured still gets a policy, and no caller writes a nil guard.
      Gates = Data.define(:table)

      class Gates
        # Reopened for {Epics}'s reason: constants and nested classes inside a
        # `Data.define do ... end` block are scoped to the enclosing module.

        # The three refusals share a shape -- a path that may be absent (a value
        # built directly rather than loaded) and a message naming the sub-table
        # -- so the prefix is spelled once here instead of three times.
        class Refusal < Error
          attr_reader :path

          def initialize(path, detail)
            @path = path
            prefix = path ? "#{path}: " : ""
            super("#{prefix}[epics.gates] #{detail}")
          end
        end

        # `gates` present but not a table (`gates = "deferred"`), the sibling of
        # {Epics::NotATable} and for its reason: `.keys` on a String is an
        # unnamed NoMethodError three frames from the file that caused it.
        class NotATable < Refusal
          attr_reader :value

          def initialize(value, path: nil)
            @value = value
            super(path, "must be a table, got #{value.class}: #{value.inspect}")
          end
        end

        # A stage name outside {Epic::STAGES}. Loud rather than ignored: a
        # silently dropped `reserch = "deferred"` leaves that stage interactive,
        # so an unattended run wedges on a gate nobody is there to answer.
        # `keys` matches {Epics::UnknownKeys}'s reader, and every unknown stage
        # is reported in one pass.
        class UnknownStages < Refusal
          attr_reader :keys

          def initialize(keys, path: nil)
            @keys = keys
            super(path, "has no stages #{keys.map(&:inspect).join(", ")}; " \
                        "the pipeline is #{Epic::STAGES.join(" -> ")}")
          end
        end

        # A policy name no recipe answers to -- including a value of the wrong
        # TYPE, which simply fails the membership test rather than being coerced
        # first ({Epics::InvalidHome}'s posture).
        class UnknownPolicies < Refusal
          attr_reader :policies

          def initialize(policies, path: nil)
            @policies = policies
            super(path, "names unknown gate policies #{policies.map(&:inspect).join(", ")}; " \
                        "known policies: #{Approval::Gate::Policies.names.join(", ")}")
          end
        end

        # @param table [Object] whatever `[epics] gates` parsed to; nil when absent
        # @param path [String, nil] the config file, named in every refusal
        # @return [Gates]
        def self.from(table, path: nil)
          table = {} if table.nil?
          check!(table, path:)
          new(table:)
        end

        # A caller that is not {.from} may reasonably hand a plain Hash, or nil
        # for "none configured". Coercing here is what makes {Epics#initialize}'s
        # guard total: a typo'd policy name in a hand-built value raises
        # {UnknownPolicies} naming it, where storing the Hash as handed deferred
        # the failure to an unnamed NoMethodError inside {Config#gate_policy_for}
        # -- no path, no key, and a stack frame away from the mistake.
        def self.coerce(gates) = gates.is_a?(self) ? gates : from(gates)

        # @return [Gates] the value an absent sub-table yields
        def self.empty = EMPTY

        # The closed-set checks, shared by {.from} (which names the config file)
        # and by {#initialize} (which cannot, and passes nil).
        #
        # @raise [NotATable, UnknownStages, UnknownPolicies]
        def self.check!(table, path: nil)
          raise NotATable.new(table, path:) unless table.is_a?(Hash)
          # An empty table has no key and no value to judge, so it is vacuously
          # valid -- and answering HERE, before either closed set is read, is
          # also what lets {EMPTY} be built while this file loads (see the note
          # at {Config::EMPTY}). Every non-empty table arrives through
          # {Config.load}, long after both sets exist.
          return if table.empty?

          unknown = table.keys - Epic::STAGES
          raise UnknownStages.new(unknown, path:) unless unknown.empty?

          unnamed = table.values.reject { |policy| Approval::Gate::Policies.known?(policy) }
          raise UnknownPolicies.new(unnamed, path:) unless unnamed.empty?
        end

        # Validated in the value's own constructor as well as in {.from}, the
        # {Epics#initialize} precedent: a typo that CONSTRUCTS would reach
        # {Approval::Gate::Policies.for} as an unbuildable name.
        def initialize(table:)
          self.class.check!(table)

          # Interned and re-frozen rather than stored as handed over: the caller's
          # Hash is theirs to keep mutating, and this value rides inside a
          # Ractor-shareable {Config}.
          super(table: table.to_h { |stage, policy| [-stage, -policy] }.freeze)
        end

        # Total by construction -- an unconfigured stage runs the default.
        #
        # @param stage [#to_s] an {Epic::Stage} or its name
        # @return [String] the policy name that stage's gates run under
        def policy_for(stage) = table.fetch(stage.to_s, Approval::Gate::Policies::DEFAULT)

        EMPTY = new(table: {}).freeze
        private_constant :EMPTY
      end

      # @param table [Object] whatever `raw["epics"]` parsed to: a Hash when
      #   the table is present and well-formed, nil when it is absent, or
      #   anything else a project wrote in its place (`epics = "x"`).
      # @param path [String] the config file's path, threaded into every
      #   error raised here so a refusal names the file to open, not just the
      #   value inside it.
      # @return [Epics]
      def self.from(table, path:)
        table = {} if table.nil?
        raise NotATable.new(table, path:) unless table.is_a?(Hash)

        unknown = table.keys - KEYS
        raise UnknownKeys.new(unknown, path:) unless unknown.empty?

        new(home: home_from(table, path:), gates: Gates.from(table["gates"], path:))
      end

      # `home`'s own closed-set check, split out so this entry point reads as
      # one line per key. Each key `[epics]` learns owns its reading; keeping
      # them inline is what made this method grow past Metrics/AbcSize when
      # `gates` arrived, and the next key would do it again.
      def self.home_from(table, path:)
        home = table.fetch("home", "xdg")
        raise InvalidHome.new(home, path:) unless HOME_VALUES.include?(home)

        home.to_sym
      end
      private_class_method :home_from

      # Closed-set validation belongs to the VALUE, not only to the
      # TOML-parsing path that usually builds it (T1's `Epic::Issue` does the
      # same): `Epics.new(home: :bogus)` must refuse just as loudly as a bad
      # `config.toml`, so a value built by any future caller that isn't
      # `.from` can never carry a symbol T9's `case epics_home` doesn't
      # expect. `.from`'s own check stays -- it names the config path, which
      # this constructor-level guard cannot.
      #
      # `gates` earns the SAME guarantee through {Gates.coerce}, and for the
      # same reason spelled one key over: a hand-built `gates: {"research" =>
      # "yolo"}` used to construct here and fail later as an unnamed
      # NoMethodError from {Config#gate_policy_for}. Coercion refuses the typo
      # by name and accepts the two shapes a caller plausibly means -- a plain
      # Hash, and nil for "none configured".
      def initialize(home:, gates: Gates.empty)
        raise InvalidHome.new(home, path: nil) unless HOME_VALUES.map(&:to_sym).include?(home)

        super(home:, gates: Gates.coerce(gates))
      end
    end

    Answers = Data.define(:allow, :deny, :deny_tools)

    # The `[approval]` table: the answers a human chose to remember, so a call
    # shape they have already ruled on is never put to them twice.
    # {Approval::Remembered} interprets them; this class only decides whether
    # the file says something well-formed, which is why it names no tool, no
    # verdict and no precedence of its own.
    #
    # It is `Answers` rather than `Approval`, and that name is FORCED: a
    # `Config::Approval` constant would win Ruby's lexical lookup over
    # `Lain::Approval` for every reference inside this file -- {Epics::Gates}
    # asks `Approval::Gate::Policies.known?` -- and the failure would be a
    # NameError nowhere near the constant that caused it.
    #
    # The shape is an array of tables per strength, because that is the one
    # TOML form a writer can APPEND to without rewriting the file: every other
    # table, and every comment a human wrote, survives an answer being
    # remembered.
    #
    #   [[approval.allow]]
    #   tool = "read_file"
    #   input = { path = "README.md" }
    #
    #   [[approval.deny_tool]]
    #   tool = "bash"
    class Answers
      # Reopened rather than written in the `Data.define` block, per
      # {Request::SYSTEM_PREFIX}: nested constants declared there belong to the
      # enclosing module instead.
      TOOL = "tool"
      INPUT = "input"
      # Two strengths keyed by call SHAPE, one by tool. Emacs'
      # `ignored-local-variable-values` (this variable at this value) against
      # `ignored-local-variables` (this variable, whatever it says).
      ALLOW = "allow"
      DENY = "deny"
      SHAPED = [ALLOW, DENY].freeze
      # Singular, because each `[[approval.deny_tool]]` is ONE tool's denial;
      # the reader over all of them is {#deny_tools}.
      TOOL_WIDE = "deny_tool"
      KEYS = [*SHAPED, TOOL_WIDE].freeze

      # The shape of every refusal in this table: a path that may be absent (a
      # value built directly rather than loaded) in front of a detail that
      # names the table it came from. {Epics::Gates::Refusal}'s posture.
      class Refusal < Error
        attr_reader :path

        def initialize(path, detail)
          @path = path
          prefix = path ? "#{path}: " : ""
          super("#{prefix}#{detail}")
        end
      end

      # `[approval]` present but not a table (`approval = "yes"`), the sibling
      # of {Epics::NotATable}: `.keys` on a String is an unnamed NoMethodError
      # three frames from the file that caused it.
      class NotATable < Refusal
        attr_reader :value

        def initialize(value, path: nil)
          @value = value
          super(path, "[approval] must be a table, got #{value.class}: #{value.inspect}")
        end
      end

      # A typo for one of the three strengths. Loud rather than ignored: a
      # silently dropped `[[approval.alow]]` reads as an answer that was
      # remembered and is not, so the human is asked again and cannot see why.
      class UnknownKeys < Refusal
        attr_reader :keys

        def initialize(keys, path: nil)
          @keys = keys
          super(path, "[approval] has no keys #{keys.map(&:inspect).join(", ")}; known keys: #{KEYS.join(", ")}")
        end
      end

      # `allow = "read_file"` -- the single-table form of a key that is a list
      # of tables. Named here because the fix is a syntax change
      # (`[[approval.allow]]`), not a value change.
      class NotAList < Refusal
        attr_reader :key, :value

        def initialize(key, value, path: nil)
          @key = key
          @value = value
          super(path, "[approval] #{key} is a list of tables ([[approval.#{key}]]), got #{value.class}")
        end
      end

      # One entry that cannot mean anything: no tool, a key this table does not
      # have, or an input carrying something that is not a scalar. Every entry
      # in this file was written to be MATCHED against a live call, and an
      # entry that can never match is indistinguishable from an answer that was
      # never remembered.
      class MalformedEntry < Refusal
        attr_reader :key, :entry

        def initialize(key, entry, detail, path: nil)
          @key = key
          @entry = entry
          super(path, "[[approval.#{key}]] #{detail}: #{entry.inspect}")
        end
      end

      # @param table [Object] whatever `raw["approval"]` parsed to; nil when absent
      # @param path [String, nil] the config file, named in every refusal
      # @return [Answers]
      def self.from(table, path: nil)
        table = {} if table.nil?
        check!(table, path:)

        new(allow: table.fetch(ALLOW, []), deny: table.fetch(DENY, []),
            deny_tools: table.fetch(TOOL_WIDE, []).map { |entry| entry[TOOL] })
      end

      # {Epics::Gates.coerce}'s reason, one table over: a caller that is not
      # {.from} may reasonably hand a plain Hash, or nil for "nothing
      # remembered", and coercing here is what keeps a hand-built {Config} from
      # carrying a shape the loader would have refused.
      def self.coerce(answers) = answers.is_a?(self) ? answers : from(answers)

      # @return [Answers] the value an absent table yields
      def self.empty = EMPTY

      # @raise [NotATable, UnknownKeys, NotAList, MalformedEntry]
      def self.check!(table, path: nil)
        raise NotATable.new(table, path:) unless table.is_a?(Hash)

        unknown = table.keys - KEYS
        raise UnknownKeys.new(unknown, path:) unless unknown.empty?

        table.each { |key, list| check_list!(key, list, path:) }
      end

      def self.check_list!(key, list, path: nil)
        raise NotAList.new(key, list, path:) unless list.is_a?(Array)

        list.each { |entry| check_entry!(key, entry, path:) }
      end

      # Public because {#initialize} runs it too: a value built by hand carries
      # entries that never came through {.from}, and the closed-set check
      # belongs to the VALUE as much as to the parse ({Epics#initialize}).
      def self.check_entry!(key, entry, path: nil)
        raise MalformedEntry.new(key, entry, "must be a table", path:) unless entry.is_a?(Hash)
        # Blank as well as absent: `tool = ""` names no tool, so it can never
        # match a call, and this class exists to refuse exactly that.
        raise MalformedEntry.new(key, entry, "needs a #{TOOL} name", path:) unless named?(entry)

        check_fields!(key, entry, path:)
      end

      def self.named?(entry) = entry[TOOL].is_a?(String) && !entry[TOOL].strip.empty?

      # A tool-wide denial has no call shape by definition, so an `input`
      # beside it is a misunderstanding that would otherwise sit in the file
      # doing nothing. A shaped answer needs the key even when the tool takes
      # no fields (`input = {}`), because an entry with no input silently
      # matches only a call whose every field is unset -- which is not what
      # anyone writing it means.
      def self.check_fields!(key, entry, path: nil)
        known = key == TOOL_WIDE ? [TOOL] : [TOOL, INPUT]
        extra = entry.keys - known
        raise MalformedEntry.new(key, entry, "has no #{extra.map(&:inspect).join(", ")}", path:) unless extra.empty?
        raise MalformedEntry.new(key, entry, "needs an #{INPUT} table", path:) if missing_input?(key, entry)

        check_input!(key, entry, path:)
      end

      def self.missing_input?(key, entry) = key != TOOL_WIDE && !entry.key?(INPUT)

      def self.check_input!(key, entry, path: nil)
        input = entry.fetch(INPUT, {})
        raise MalformedEntry.new(key, entry, "#{INPUT} must be a table", path:) unless input.is_a?(Hash)

        loose = input.reject { |_, value| scalar?(value) }
        return if loose.empty?

        raise MalformedEntry.new(key, entry, "#{INPUT} #{loose.keys.map(&:inspect).join(", ")} is not a scalar", path:)
      end

      # What a {Tool::Input} field can hold, which is also what TOML can carry
      # back unchanged. A datetime parses fine and could never match a call, so
      # it is refused with the arrays and tables.
      def self.scalar?(value) = value.is_a?(String) || value.is_a?(Numeric) || [true, false].include?(value)

      private_class_method :check_list!, :named?, :check_fields!, :missing_input?, :check_input!

      # Validated in the value's own constructor as well as in {.from}, the
      # {Epics#initialize} precedent: an entry that CONSTRUCTS but can never
      # match is an answer silently forgotten.
      def initialize(allow: [], deny: [], deny_tools: [])
        super(allow: settled(ALLOW, allow), deny: settled(DENY, deny), deny_tools: named(deny_tools))
      end

      private

      # Re-frozen rather than stored as handed over: the caller's Hashes are
      # theirs to keep mutating, and this value rides inside a
      # Ractor-shareable {Config}.
      def settled(key, entries)
        entries.map do |entry|
          self.class.check_entry!(key, entry)
          { TOOL => -entry[TOOL], INPUT => scalars(entry.fetch(INPUT, {})) }.freeze
        end.freeze
      end

      # The third member earns the SAME constructor guarantee as the other two,
      # through the same validator: `deny_tools: [42]` used to construct and
      # store `"42"`, a refusal for a tool that does not exist, silently
      # forgotten -- while `.from` refused it. One of them was lying.
      def named(names)
        names.map do |name|
          self.class.check_entry!(TOOL_WIDE, { TOOL => name })
          -name.to_s
        end.freeze
      end

      # Interning is deliberate for the field NAMES (a bounded set) and
      # deliberately absent for the values ({Risk::Keepsake.scalar}'s reason:
      # an unbounded tool argument in the fstring table leaks for the life of
      # the process).
      def scalars(input)
        input.to_h { |field, value| [-field.to_s, value.is_a?(String) ? value.dup.freeze : value] }.freeze
      end

      EMPTY = new.freeze
      private_constant :EMPTY
    end

    # @param root [String] a project root; `.lain/config.toml` is resolved under it
    # @return [Config]
    # @raise [Malformed] when the file exists but cannot be read as TOML (bad
    #   syntax, invalid encoding, or an unreadable/directory path)
    # @raise [Epics::NotATable] when `[epics]` is present but not a table
    # @raise [Epics::UnknownKeys] when `[epics]` carries a key this class does not know
    # @raise [Epics::InvalidHome] when `home` is set to anything but xdg/repo
    # @raise [Epics::Gates::NotATable] when `[epics.gates]` is present but not a table
    # @raise [Epics::Gates::UnknownStages] when it keys a stage outside {Epic::STAGES}
    # @raise [Epics::Gates::UnknownPolicies] when it names a policy no recipe builds
    # @raise [Answers::NotATable] when `[approval]` is present but not a table
    # @raise [Answers::UnknownKeys] when it names a strength this class does not know
    # @raise [Answers::NotAList] when a strength is not a list of tables
    # @raise [Answers::MalformedEntry] when a remembered entry could never match a call
    def self.load(root: Dir.pwd)
      path = File.join(root, ".lain", "config.toml")
      return empty unless File.exist?(path)

      raw =
        begin
          Tomlrb.load_file(path)
        rescue Tomlrb::ParseError, ArgumentError, SystemCallError => e
          # ArgumentError: invalid byte sequence (bad encoding). SystemCallError:
          # EACCES/EISDIR and siblings -- "the file is there but unusable" is one
          # failure to a caller, whichever of the three raised it.
          raise Malformed.new(path, e)
        end

      new(epics: Epics.from(raw["epics"], path:), approval: Answers.from(raw["approval"], path:))
    end

    # @return [Config] every field at its default -- the value an absent file yields.
    def self.empty
      EMPTY
    end

    attr_reader :epics, :approval

    def initialize(epics:, approval: Answers.empty)
      @epics = epics
      @approval = Answers.coerce(approval)
      freeze
    end

    def epics_home = epics.home

    # @param stage [#to_s] an {Epic::Stage} or its name
    # @return [String] the gate policy that stage runs under, "interactive"
    #   unless `[epics.gates]` says otherwise
    def gate_policy_for(stage) = epics.gates.policy_for(stage)

    # `instance_of?`, not `is_a?`: a subclass instance and a Config instance
    # must agree in BOTH directions (`a == b` iff `b == a`), which `is_a?`
    # breaks (a subclass `is_a?` its parent; a parent is never `is_a?` its
    # subclass). `#hash` mixes in `self.class` for the same reason `==` checks
    # it -- two values a Hash should treat as distinct keys must not collide.
    def ==(other)
      other.instance_of?(self.class) && epics == other.epics && approval == other.approval
    end
    alias eql? ==

    def hash
      [self.class, epics, approval].hash
    end

    # The default `gates` table must stay EMPTY. {Epics::Gates.check!} reads
    # `Epic::STAGES` and {Approval::Gate::Policies}, and neither exists yet
    # while this file loads -- config.rb is twelfth in lain.rb's manifest,
    # against approval/'s forty-ninth and epic/'s sixty-eighth. A non-empty
    # default here breaks `require "lain"` outright, which is every spec at
    # once rather than one, so no test is owed for it.
    EMPTY = new(epics: Epics.new(home: :xdg)).freeze
    private_constant :EMPTY
  end
end
