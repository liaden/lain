# frozen_string_literal: true

module Lain
  class Config
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

      # Where an epic tree may live, spelled as the TOML spells it. Strings, not
      # Symbols, because membership is tested against what the parser produced --
      # a wrong-TYPED `home` has to fail that test rather than be coerced first.
      HOME_VALUES = %w[xdg repo].freeze

      # Every key `[epics]` understands. An unknown one is refused rather than
      # ignored, so this list is also the correction {UnknownKeys} offers back.
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
  end
end
