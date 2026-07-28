# frozen_string_literal: true

require "tomlrb"

module Lain
  # Reads `<root>/.lain/config.toml`. Absence is not an error -- {.load} on a
  # root with no file returns the same value {.empty} does, so a caller never
  # writes an `if File.exist?` guard of its own (Null Object).
  #
  # Only the `[epics]` table is understood today. Every OTHER top-level table
  # is tolerated and ignored: other consumers are coming (chat-ux's prompt
  # config may converge on this same file later), and a table this class
  # doesn't yet read is not this class's typo to catch. `[epics]` is
  # {Epics}'s whole surface, so a typo or a wrong-shaped value inside it is
  # loud instead of silently defaulting or crashing three call frames deep.
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
    Epics = Data.define(:home)

    # Reopened (not a body inside the `Data.define do ... end` block) because
    # constants and nested classes defined THERE are lexically scoped to
    # `Lain::Config`, not to `Epics` itself -- a documented trap, see
    # `Request::SYSTEM_PREFIX` for the precedent.
    class Epics
      HOME_VALUES = %w[xdg repo].freeze
      KEYS = %w[home].freeze

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

        home = table.fetch("home", "xdg")
        raise InvalidHome.new(home, path:) unless HOME_VALUES.include?(home)

        new(home: home.to_sym)
      end

      # Closed-set validation belongs to the VALUE, not only to the
      # TOML-parsing path that usually builds it (T1's `Epic::Issue` does the
      # same): `Epics.new(home: :bogus)` must refuse just as loudly as a bad
      # `config.toml`, so a value built by any future caller that isn't
      # `.from` can never carry a symbol T9's `case epics_home` doesn't
      # expect. `.from`'s own check stays -- it names the config path, which
      # this constructor-level guard cannot.
      def initialize(home:)
        raise InvalidHome.new(home, path: nil) unless HOME_VALUES.map(&:to_sym).include?(home)

        super
      end
    end

    # @param root [String] a project root; `.lain/config.toml` is resolved under it
    # @return [Config]
    # @raise [Malformed] when the file exists but cannot be read as TOML (bad
    #   syntax, invalid encoding, or an unreadable/directory path)
    # @raise [Epics::NotATable] when `[epics]` is present but not a table
    # @raise [Epics::UnknownKeys] when `[epics]` carries a key this class does not know
    # @raise [Epics::InvalidHome] when `home` is set to anything but xdg/repo
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

      new(epics: Epics.from(raw["epics"], path:))
    end

    # @return [Config] every field at its default -- the value an absent file yields.
    def self.empty
      EMPTY
    end

    attr_reader :epics

    def initialize(epics:)
      @epics = epics
      freeze
    end

    def epics_home = epics.home

    # `instance_of?`, not `is_a?`: a subclass instance and a Config instance
    # must agree in BOTH directions (`a == b` iff `b == a`), which `is_a?`
    # breaks (a subclass `is_a?` its parent; a parent is never `is_a?` its
    # subclass). `#hash` mixes in `self.class` for the same reason `==` checks
    # it -- two values a Hash should treat as distinct keys must not collide.
    def ==(other)
      other.instance_of?(self.class) && epics == other.epics
    end
    alias eql? ==

    def hash
      [self.class, epics].hash
    end

    EMPTY = new(epics: Epics.new(home: :xdg)).freeze
    private_constant :EMPTY
  end
end
