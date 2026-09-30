# frozen_string_literal: true

module Lain
  class Config
    # The `epics` table, its own collaborator rather than a private method on
    # {Config}: other top-level tables are coming, and each one earns exactly
    # this shape -- one small class that knows its own keys and its own allowed
    # values, refusing through {Config::Refusal} -- rather than {Config}
    # accreting another `*_from` method per table it learns to read.
    #
    # The verb's keyword is `home` (`epics home: :repo`); the Ruby reader stays
    # `#epics_home`. `epics epics_home:` would stutter (`epics.epics_home`).
    Epics = Data.define(:home, :gates, :width)

    class Epics
      # Reopened (not a body inside the `Data.define do ... end` block) because
      # constants and nested classes defined THERE are lexically scoped to
      # `Lain::Config`, not to `Epics` -- see `Request::SYSTEM_PREFIX`.

      # Where an epic tree may live, spelled as the TOML spells it. Strings, not
      # Symbols, because membership is tested against what the parser produced --
      # a wrong-TYPED `home` has to fail that test rather than be coerced first.
      HOME_VALUES = %w[xdg repo].freeze

      # An unknown key is refused rather than ignored, so this list is also the
      # correction the refusal offers back.
      KEYS = %w[home gates width].freeze

      # The verb of `.lain/config.rb` that declares this table, as every refusal
      # here names it.
      TABLE = "`epics`"

      # @param table [Object] whatever `raw["epics"]` parsed to: a Hash, nil when
      #   the table is absent, or anything a project wrote in its place
      # @param path [String] the config file, threaded into every refusal raised
      #   here so it names the file to open
      # @return [Epics]
      # @raise [Refusal] naming what is wrong with the table
      def self.from(table, path:)
        table = {} if table.nil?
        raise Refusal.not_a_table(table, path:, table: TABLE) unless table.is_a?(Hash)

        unknown = table.keys - KEYS
        raise Refusal.unknown_keys(unknown, known: KEYS, path:, table: TABLE) unless unknown.empty?

        new(home: home_from(table, path:), gates: Gates.from(table["gates"], path:),
            width: width!(table["width"], path:))
      end

      # `home`'s own closed-set check, split out so `.from` reads as one line per
      # key: keeping them inline is what pushed that method past
      # Metrics/AbcSize when `gates` arrived, and the next key would do it again.
      def self.home_from(table, path:)
        home = table.fetch("home", "xdg")
        raise invalid_home(home, path:) unless HOME_VALUES.include?(home)

        home.to_sym
      end

      # Named `epics_home` rather than `epics home:`, because that is the Ruby
      # reader a caller who built this value by hand has in front of them --
      # which is also why this refusal names no table.
      #
      # @return [Refusal]
      def self.invalid_home(value, path: nil)
        Refusal.new("`epics` home: #{value.inspect} is not one of #{HOME_VALUES.join(", ")}", path:, value:)
      end
      private_class_method :home_from

      # How many issues a driven epic carries at once, when the project has an
      # opinion. ABSENT IS NOT ZERO: nil means the project said nothing and the
      # driver derives its own, so it passes through rather than being defaulted
      # to a number here -- a number here would be a second answer to the
      # question {CLI::EpicDriver::Run.width_for} exists to hold.
      #
      # The closed set is the whole numbers above zero, checked for BOTH the
      # parsed and the hand-built value the way `home` is: a zero constructs
      # fine and then drives an epic that launches nothing while reporting
      # nothing wrong, which is the failure this whole class is shaped against.
      #
      # `is_a?(Integer)` rather than a coercion, so `"2"` and `2.0` refuse
      # instead of being read as a number the file did not say.
      #
      # @param value [Object] whatever the table held, or nil for an absent key
      # @param path [String, nil] the config file, named when there is one
      # @return [Integer, nil]
      # @raise [Refusal]
      def self.width!(value, path: nil)
        return nil if value.nil?
        raise invalid_width(value, path:) unless value.is_a?(Integer) && value.positive?

        value
      end

      # Named `epics width:` rather than a Ruby reader, because the TOML
      # spelling and the reader are the same word -- so the refusal can send a
      # reader to the line of TOML, which {Refusal} says is the point of it.
      #
      # @return [Refusal]
      def self.invalid_width(value, path: nil)
        Refusal.new("width #{value.inspect} is not a whole number of issues above zero",
                    path:, table: TABLE, key: "width", value:)
      end

      # Closed-set validation belongs to the VALUE, not only to the TOML-parsing
      # path that usually builds it (`Epic::Issue` does the same):
      # `Epics.new(home: :bogus)` must refuse as loudly as a bad `config.rb`.
      # `.from`'s own check stays -- it names the config path, which this
      # constructor-level guard cannot.
      #
      # `gates` earns the SAME guarantee through {Gates.coerce}: a hand-built
      # `gates: {"research" => "yolo"}` used to construct here and fail later as
      # an unnamed NoMethodError from {Config#gate_policy_for}. `width` earns it
      # through {.width!}, the one check both paths run.
      def initialize(home:, gates: Gates.empty, width: nil)
        raise self.class.invalid_home(home) unless HOME_VALUES.map(&:to_sym).include?(home)

        super(home:, gates: Gates.coerce(gates), width: self.class.width!(width))
      end
    end
  end
end
