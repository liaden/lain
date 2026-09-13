# frozen_string_literal: true

require "tomlrb"

# The tables load before this file's body, which builds {Config::EMPTY} -- and so an
# {Epics} -- while it loads. `config/gates` REOPENS `Epics` to hang the sub-table on
# it, so it follows the file that defines it. {Config::Refusal} is first: every
# table raises it, so it has to exist before any of them is read.
require_relative "config/refusal"
require_relative "config/epics"
require_relative "config/gates"
require_relative "config/answers"
require_relative "config/isolation"
# Last: {Config::Resolved} builds all four tables above, and the two that live
# outside this subtree, on demand.
require_relative "config/resolved"

module Lain
  # Reads `<root>/.lain/config.toml`. Absence is not an error -- {.load} on a
  # root with no file returns the same value {.empty} does, so a caller never
  # writes an `if File.exist?` guard of its own (Null Object).
  #
  # `[epics]`, `[approval]`, `[isolation]`, `[sensitivity]`, `[shell]` and
  # `[tests]` are understood. Every OTHER top-level table is tolerated and ignored: other
  # consumers are coming (chat-ux's prompt config may converge on this same file
  # later), and a table this class doesn't yet read is not this class's typo to
  # catch. Each table it DOES read is one small class's whole surface -- {Epics},
  # {Answers}, {Isolation}, {Sensitivity::Rules}, {Shell::Exclusions} -- so a typo or a wrong-shaped
  # value inside one is loud instead of silently defaulting or crashing three
  # call frames deep.
  #
  # `[sensitivity]`, `[shell]` and `[tests]` are read by {.sensitivity},
  # {.shell_exclusions} and {.test_layout}, NOT by {.load}, which is a decision rather than an
  # oversight: those two readers and {.load} have opposite postures about a
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
    # @raise [Refusal] when `[epics]`, `[epics.gates]`, `[approval]` or `[isolation]`
    #   is not a table, carries a key that table does not know, holds a value
    #   outside that key's rule, or -- under `[approval]` -- carries a remembered
    #   entry that could never match a call
    def self.load(root: Dir.pwd) = resolved(root).config

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
    # @raise [Refusal] when `[sensitivity]` is not a table, names a strength this
    #   class does not know, gives one as a single value rather than a list, or
    #   carries a pattern that could never match anything
    def self.sensitivity(root:) = resolved(root).sensitivity

    # The `[shell]` table: the programs this project has ruled out of every
    # shell command, whatever else the command says.
    #
    # Read on its own for the same reason `[sensitivity]` is, and it is the same
    # reason twice rather than a habit: this table RESTRICTS, so an exclusion
    # silently not being in force is the worst outcome available. {.load}
    # tolerates a typo because there it costs only the mistyped table's own
    # feature; here it would cost a refusal a project asked for, and the two
    # postures cannot be had from one reader.
    #
    # `root:` is REQUIRED, as {.sensitivity}'s is: the caller holds a resolved
    # {Project}, and a working-directory default is a divergence.
    #
    # @param root [String] a project root; `.lain/config.toml` is resolved under it
    # @return [Shell::Exclusions] empty -- restricting nothing -- when the file
    #   or the table is absent
    # @raise [Malformed] when the file exists but cannot be read as TOML
    # @raise [Refusal] when `[shell]` is not a table, names a key this class does
    #   not read, gives `exclude` as a single value rather than a list, or
    #   carries an entry that could never match a program
    def self.shell_exclusions(root:) = resolved(root).shell_exclusions

    # The `[tests]` table: where this project keeps its tests, which the
    # layout guard holds a test file's path to.
    #
    # Read on its own for the reason `[sensitivity]` is: this table restricts
    # where a test may be written, so a misspelt key must refuse rather than
    # leave the project quietly unguarded.
    #
    # With no table the layout falls back to the preset of a framework the
    # caller passes, which serves a caller choosing how to run the tests.
    # Detection is the caller's, because the test harness that knows how loads
    # long after this file does.
    #
    # @param root [String] a project root; `.lain/config.toml` is resolved under it
    # @param framework [String, nil] a detected test framework. A caller that
    #   enforces the layout never passes one, so enforcement is opt-in: a
    #   detected preset imposes level roots the project never declared, and
    #   would refuse its existing flat specs as strays.
    # @return [TestLayout] {TestLayout::None} when neither says what the layout is
    # @raise [Malformed] when the file exists but cannot be read as TOML
    # @raise [Refusal] when `[tests]` is not a table, names a key the layout does
    #   not read, names no preset, or holds a value outside its key's rule
    def self.test_layout(root:, framework: nil) = resolved(root).test_layout(framework:)

    # The shared parse, so the four readers above cannot disagree about what
    # the file says -- only about how loudly to complain. It is shared across
    # the PROCESS, not merely across these four: {Project::Resolver} reads the
    # same file for a `root =` before any of them, and comes through here too.
    # {Resolved} carries what invalidates it.
    #
    # @param root [String] a project root
    # @return [Resolved]
    def self.resolved(root) = Resolved.for(ProjectDir.new(root:).config)

    # Private: the four readers above are this class's whole door onto the file,
    # and {Resolved.for} is the door for anything holding a path already.
    private_class_method :resolved

    # @return [Config] every field at its default -- the value an absent file yields.
    def self.empty
      EMPTY
    end

    attr_reader :epics, :approval, :isolation

    def initialize(epics:, approval: Answers.empty, isolation: Isolation.empty)
      @epics = epics
      @approval = Answers.coerce(approval)
      @isolation = Isolation.coerce(isolation)
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
      other.instance_of?(self.class) && epics == other.epics && approval == other.approval &&
        isolation == other.isolation
    end
    alias eql? ==

    def hash
      [self.class, epics, approval, isolation].hash
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
