# frozen_string_literal: true

module Lain
  module Shell
    Exclusions = Data.define(:patterns)

    # The `[shell]` table: the programs a project has ruled out, whatever else a
    # command says.
    #
    #   [shell]
    #   exclude = ["curl", "nc", "*sh"]
    #
    # This is the capability set {Verdict} consults, so the whole interface is
    # `permits?(program)` and the answer is about a bare program name --
    # `/usr/bin/curl` and `./curl` reach here as `curl`, which is what makes an
    # exclusion unevadable by qualifying it. Run the same matching the other way
    # and it would be a hole: `/tmp/evil/cat` also basenames to `cat`. Basenames
    # are sound for a denylist and unsound for an allowlist, and this table is
    # only ever the first.
    #
    # An entry is a `File.fnmatch?` pattern over that name: `*`, `?`, `[a-c]`
    # and a backslash escape mean what they do in a glob, while brace
    # alternation does NOT -- `{cat,rm}` matches those characters literally,
    # since `File::FNM_EXTGLOB` is set nowhere in this config.
    #
    # Read by {Config.shell_exclusions} rather than by `Config.load`, for the
    # reason {Config.sensitivity} carries: a table that RESTRICTS must refuse a
    # typo loudly, where `Config.load` can afford to tolerate one.
    #
    # Every key here can only ever subtract capability, which is why a wildcard
    # is legal: `exclude = ["*"]` is the strictest posture the file can express.
    # {Sensitivity::Rules} refuses one under `exempt` for the mirror-image
    # reason -- that key is the one that hands capability back.
    class Exclusions
      # The constants live on this reopen rather than in the `Data.define`
      # block, where they would scope to {Shell} instead (see
      # {Request::SYSTEM_PREFIX}).
      EXCLUDE = "exclude"
      KEYS = [EXCLUDE].freeze
      # A program whose name begins with a dot is still a program, so `*` has to
      # reach it for the wildcard to mean what the file says. The same flag
      # {Sensitivity::Rules} matches with, so the config speaks one glob dialect.
      GLOB = File::FNM_DOTMATCH

      # The table as `config.toml` spells it, which is how every refusal here
      # names it.
      TABLE = "[shell]"

      # @param table [Object] whatever `raw["shell"]` parsed to; nil when absent
      # @param path [String, nil] the config file, named in every refusal
      # @return [Exclusions]
      def self.from(table, path: nil)
        table = {} if table.nil?
        raise Config::Refusal.not_a_table(table, path:, table: TABLE) unless table.is_a?(Hash)

        unknown = table.keys - KEYS
        # A silently ignored `excluded` reads as an exclusion that is in force
        # and is not.
        raise Config::Refusal.unknown_keys(unknown, known: KEYS, path:, table: TABLE) unless unknown.empty?

        new(patterns: compile(table.fetch(EXCLUDE, []), path:))
      end

      # @return [Exclusions] the value an absent table yields, and the one that
      #   restricts nothing
      def self.empty = EMPTY

      # @raise [Config::Refusal]
      def self.compile(patterns, path: nil)
        raise not_a_list(patterns, path:) unless patterns.is_a?(Array)

        patterns.map { |pattern| settled(pattern, path:) }
      end

      # A frozen COPY: the patterns arrive from a TOML parse, so the caller
      # keeps them and is free to keep mutating them, while this value has to
      # stay `Ractor.shareable?`. `dup.freeze` rather than `-@`, because
      # interning an unbounded config string leaks it into the fstring table for
      # the life of the process.
      def self.settled(pattern, path: nil)
        check!(pattern, path:)
        pattern.dup.freeze
      end

      # A pattern that survives compilation and then raises inside
      # `File.fnmatch?` would break every LATER call rather than its own, so one
      # line in a committed config would take the gate down for good. Refused
      # here, where the refusal names the file.
      def self.check!(pattern, path: nil)
        raise malformed(pattern, "must be a string", path:) unless pattern.is_a?(String)
        raise malformed(pattern, "must be matchable text", path:) unless Sensitivity.readable?(pattern)
        raise malformed(pattern, "must not be blank", path:) if pattern.strip.empty?
        raise malformed(pattern, "must be a program name, not a path", path:) if pattern.include?("/")
      end

      # `exclude = "curl"` -- a single value where the shape is a list.
      #
      # @return [Config::Refusal]
      def self.not_a_list(patterns, path: nil)
        Config::Refusal.new("#{EXCLUDE} is a list of program names, got #{patterns.class}",
                            path:, table: TABLE, key: EXCLUDE, value: patterns)
      end

      # An entry that can never match anything is indistinguishable from one
      # nobody wrote, which for a table of refusals is the worst outcome
      # available.
      #
      # @return [Config::Refusal]
      def self.malformed(pattern, detail, path: nil)
        Config::Refusal.new("#{EXCLUDE} #{detail}: #{pattern.inspect}",
                            path:, table: TABLE, key: EXCLUDE, value: pattern)
      end

      private_class_method :compile, :settled, :check!, :not_a_list, :malformed

      # Validated here too, {Sensitivity::Rules}' precedent: a value built by
      # hand carries entries that never came through {.from}.
      def initialize(patterns: [])
        super(patterns: self.class.send(:compile, patterns).freeze)
      end

      # Total, and totality here is an ORDER rather than a rescue. A NUL byte
      # parses clean into an ordinary word (`parse.rb:86`) and a UTF-16 one
      # arrives the same way; splitting such a name is itself what raises, so
      # readability is asked BEFORE the string is touched and the guard must not
      # migrate below the split -- {Verdict} fails toward abstain and cannot be
      # handed an exception. Both guards REFUSE, because a name this object
      # cannot read is one it cannot clear. An empty table is the exception and
      # has to be: it restricts nothing, so it must answer as the permissive
      # default does, or a project with no config would start denying what it
      # permits today.
      #
      # @param program [String] a program name as the parse reconstructed it
      # @return [Boolean] false when this table has ruled the program out
      def permits?(program)
        return true if patterns.empty?
        return false unless program.is_a?(String) && Sensitivity.readable?(program)

        name = program.rpartition("/").last
        patterns.none? { |pattern| File.fnmatch?(pattern, name, GLOB) }
      end

      EMPTY = new.freeze
      private_constant :EMPTY
    end
  end
end
