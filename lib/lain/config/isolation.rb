# frozen_string_literal: true

module Lain
  class Config
    Isolation = Data.define(:retain_days, :rebase_retries, :diff_algorithm, :conflict_style)

    # The `[isolation]` table: how long a worker's checkout may outlive its
    # lease, how many times a worker is asked to rebase itself before handback,
    # and the merge strategy lain puts on git's command line.
    #
    # Inside `Config` this constant SHADOWS `Lain::Isolation`, so a reference
    # to the subsystem from this namespace must be root-qualified.
    class Isolation
      # `is_a?(Integer)` first: TOML hands back Floats and Booleans too, and
      # `1.5 >= 1` would admit one.
      Whole = Data.define(:floor, :unit) do
        def admits?(value) = value.is_a?(Integer) && value >= floor
        def to_s = "a whole number of #{unit}, at least #{floor}"
      end

      OneOf = Data.define(:values) do
        def admits?(value) = values.include?(value)
        def to_s = "one of #{values.join(", ")}"
      end

      DEFAULTS = { "retain_days" => 7, "rebase_retries" => 1,
                   "diff_algorithm" => "histogram", "conflict_style" => "zdiff3" }.freeze

      KEYS = DEFAULTS.keys.freeze

      # `retain_days` starts at 1 because 0 would make a checkout reapable the
      # moment it was leased; `rebase_retries` starts at 0, which is how a
      # project turns worker self-sync off.
      RULES = {
        "retain_days" => Whole.new(floor: 1, unit: "days"),
        "rebase_retries" => Whole.new(floor: 0, unit: "retries"),
        "diff_algorithm" => OneOf.new(values: %w[histogram patience minimal myers].freeze),
        "conflict_style" => OneOf.new(values: %w[zdiff3 diff3 merge].freeze)
      }.freeze

      # `[isolation]` present but not a table: `.keys` on a scalar would be an
      # unnamed NoMethodError instead.
      class NotATable < Error
        attr_reader :path, :value

        def initialize(value, path:)
          @path = path
          @value = value
          super("#{Isolation.located(path)}[isolation] must be a table, got #{value.class}: #{value.inspect}")
        end
      end

      # A typo inside the table: refused rather than ignored, because a
      # misspelt `retain_days` would otherwise run silently on the default.
      class UnknownKeys < Error
        attr_reader :path, :keys

        def initialize(keys, path:)
          @path = path
          @keys = keys
          super("#{Isolation.located(path)}[isolation] has no keys #{keys.map(&:inspect).join(", ")}; " \
                "known keys: #{KEYS.join(", ")}")
        end
      end

      # Its path defaults to nil because {#initialize} raises this too, and a
      # value built directly names no config file.
      class InvalidValue < Error
        attr_reader :path, :key, :value

        def initialize(key, value, path: nil)
          @path = path
          @key = key
          @value = value
          super("#{Isolation.located(path)}[isolation] #{key} = #{value.inspect} is not #{RULES.fetch(key)}")
        end
      end

      # A hand-built table goes through the same rules as a file's rather than
      # being held as a Hash nothing validated.
      # @param value [Isolation, Object] a built value, or a table to read
      # @return [Isolation]
      def self.coerce(value) = value.is_a?(self) ? value : from(value, path: nil)

      # @return [String] the refusal's prefix: the file, when there is one
      def self.located(path) = path ? "#{path}: " : ""

      # @param table [Object] whatever `raw["isolation"]` parsed to
      # @param path [String, nil] the config file, named by every refusal
      # @return [Isolation]
      def self.from(table, path:)
        table = {} if table.nil?
        raise NotATable.new(table, path:) unless table.is_a?(Hash)

        unknown = table.keys - KEYS
        raise UnknownKeys.new(unknown, path:) unless unknown.empty?

        settings = DEFAULTS.merge(table)
        check!(settings, path:)
        new(**settings.transform_keys(&:to_sym))
      end

      # @param settings [Hash{String=>Object}] every key in {KEYS}
      # @param path [String, nil] the config file to name, nil for a value built directly
      # @raise [InvalidValue] naming the first key whose value its rule refuses
      def self.check!(settings, path: nil)
        settings.each do |key, value|
          raise InvalidValue.new(key, value, path:) unless RULES.fetch(key).admits?(value)
        end
      end

      def self.empty = EMPTY

      # The closed sets belong to the VALUE, so a hand-built table refuses as
      # loudly as a bad file; `.from`'s own check stays because only it can name
      # the file. The Strings are interned because a parsed one arrives unfrozen.
      def initialize(retain_days:, rebase_retries:, diff_algorithm:, conflict_style:)
        self.class.check!({ "retain_days" => retain_days, "rebase_retries" => rebase_retries,
                            "diff_algorithm" => diff_algorithm, "conflict_style" => conflict_style })
        super(retain_days:, rebase_retries:, diff_algorithm: -diff_algorithm, conflict_style: -conflict_style)
      end

      EMPTY = new(**DEFAULTS.transform_keys(&:to_sym))
      private_constant :EMPTY
    end
  end
end
