# frozen_string_literal: true

require "tomlrb"

# The tables load before this file's body, which builds {Config::EMPTY} -- and so an
# {Epics} -- while it loads. `config/gates` REOPENS `Epics` to hang the sub-table on
# it, so it follows the file that defines it.
require_relative "config/epics"
require_relative "config/gates"
require_relative "config/answers"

module Lain
  # Reads `<root>/.lain/config.toml`. Absence is not an error -- {.load} on a
  # root with no file returns the same value {.empty} does, so a caller never
  # writes an `if File.exist?` guard of its own (Null Object).
  #
  # `[epics]`, `[approval]` and `[sensitivity]` are understood. Every OTHER
  # top-level table is tolerated and ignored: other consumers are coming
  # (chat-ux's prompt config may converge on this same file later), and a table
  # this class doesn't yet read is not this class's typo to catch. Each table it
  # DOES read is one small class's whole surface -- {Epics}, {Answers},
  # {Sensitivity::Rules} -- so a typo or a wrong-shaped value inside one is loud
  # instead of silently defaulting or crashing three call frames deep.
  #
  # `[sensitivity]` is read by {.sensitivity} and NOT by {.load}, which is a
  # decision rather than an oversight: the two have opposite postures about a
  # typo, and reading them together forces one on both. {.sensitivity} carries
  # the argument.
  class Config
    # `path`/`cause` default to nil so a bare `raise Config::Malformed` -- a
    # caller re-raising without the specifics -- does not itself blow up with a
    # mismatched-arity ArgumentError. The wrapped parse error still arrives
    # through Ruby's own `Exception#cause` chaining, set automatically because
    # this is raised from inside the rescue that caught it.
    class Malformed < Error
      attr_reader :path

      def initialize(path = nil, cause = nil)
        @path = path
        super(describe(path, cause))
      end

      private

      # Only a genuine `Tomlrb::ParseError` means the file reached the parser
      # and was rejected. `ArgumentError` (bad encoding) and `SystemCallError`
      # (EACCES/EISDIR) mean it was never successfully READ, so calling it "not
      # valid TOML" would be a lie about what happened.
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
      path = path_for(root)
      return empty unless File.exist?(path)

      raw = read(path)
      new(epics: Epics.from(raw["epics"], path:), approval: Answers.from(raw["approval"], path:))
    end

    # The `[sensitivity]` table, and NOTHING else in the file -- what a project
    # adds to the path classifier's built-in tables, and the one thing it may
    # take away.
    #
    # Read on its own rather than off a loaded {Config}, because the two have
    # opposite postures about a typo. This table RESTRICTS, so denials silently
    # not being in force is the worst outcome available and it must refuse
    # loudly; every OTHER table GRANTS, so tolerating its own typo at the cost
    # of its own feature fails closed. Reading them together forced the strict
    # posture on both, and a typo in `[epics]` took `lain chat` down with it.
    #
    # An unparseable FILE still raises {Malformed}, because a file nobody can
    # parse is a sensitivity table nobody can read -- the one failure
    # {CLI::Wiring::BoardBuild} degrades to a notice, since only there is there
    # a human to tell.
    #
    # `root:` is REQUIRED where {.load}'s is defaulted: the one production
    # caller holds a resolved {Project}, and a working-directory default is the
    # divergence {Sensitivity.new} refuses for the same reason.
    # `spec/lain/project/root_defaults_spec.rb` is the guard, and it caught this.
    #
    # @param root [String] a project root; `.lain/config.toml` is resolved under it
    # @return [Sensitivity::Rules] empty when the file or the table is absent
    # @raise [Malformed] when the file exists but cannot be read as TOML
    # @raise [Sensitivity::Rules::NotATable] when `sensitivity` is not a table
    # @raise [Sensitivity::Rules::UnknownKeys] when it names a strength this class does not know
    # @raise [Sensitivity::Rules::NotAList] when a strength is not a list of patterns
    # @raise [Sensitivity::Rules::MalformedPattern] when a pattern could never match anything
    def self.sensitivity(root:)
      path = path_for(root)
      return Sensitivity::Rules.empty unless File.exist?(path)

      Sensitivity::Rules.from(read(path)["sensitivity"], path:)
    end

    def self.path_for(root) = File.join(root, ".lain", "config.toml")

    # The shared parse, so the two readers above cannot disagree about what the
    # file says -- only about how loudly to complain.
    def self.read(path)
      Tomlrb.load_file(path)
    rescue Tomlrb::ParseError, ArgumentError, SystemCallError => e
      # "The file is there but unusable" is one failure to a caller, whichever
      # of the three raised it; {Malformed#describe} keeps them apart in words.
      raise Malformed.new(path, e)
    end

    private_class_method :path_for, :read

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

    # `instance_of?`, not `is_a?`: equality must be symmetric, and a subclass
    # `is_a?` its parent while a parent is never `is_a?` its subclass. `#hash`
    # mixes in `self.class` for the same reason -- two values a Hash should
    # treat as distinct keys must not collide.
    def ==(other)
      other.instance_of?(self.class) && epics == other.epics && approval == other.approval
    end
    alias eql? ==

    def hash
      [self.class, epics, approval].hash
    end

    # The default `gates` table must stay EMPTY. {Epics::Gates.check!} reads
    # `Epic::STAGES` and {Approval::Gate::Policies}, and neither exists yet
    # while this file loads -- config.rb sits far above both in lain.rb's
    # manifest. A non-empty default here breaks `require "lain"` outright,
    # which is every spec at once rather than one, so no test is owed for it.
    EMPTY = new(epics: Epics.new(home: :xdg)).freeze
    private_constant :EMPTY
  end
end
