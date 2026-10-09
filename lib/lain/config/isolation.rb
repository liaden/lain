# frozen_string_literal: true

module Lain
  class Config
    Isolation = Data.define(:retain_days, :rebase_retries, :diff_algorithm, :conflict_style, :verifier, :verify,
                            :verify_timeout, :verify_keep, :batch_cap, :rebuild_cap, :check, :lint, :lint_files,
                            :check_retries)

    # The `isolation` table: how long a worker's checkout may outlive its
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

      # A list of non-empty Strings, judged in one pass so a table broken in
      # two places is refused once, naming both entries. `relative` is for the
      # scratch reset's keep list, where an absolute path would reach outside
      # the checkout.
      ArgList = Data.define(:what, :relative) do
        def admits?(value) = value.is_a?(Array) && problems(value).empty?
        def to_s = "an array of #{what}"

        def problems(value)
          return ["not an array"] unless value.is_a?(Array)

          value.each_with_index.filter_map do |entry, index|
            detail = entry_problem(entry)
            "entry #{index} #{entry.inspect} #{detail}" if detail
          end
        end

        private

        def escapes?(entry) = entry.start_with?("/") || entry.split("/").include?("..")

        def entry_problem(entry)
          return "must be a string" unless entry.is_a?(String)
          return "must not be blank" if entry.strip.empty?

          "must stay inside the checkout" if relative && escapes?(entry)
        end
      end

      DEFAULTS = { "retain_days" => 7, "rebase_retries" => 1,
                   "diff_algorithm" => "histogram", "conflict_style" => "zdiff3",
                   "verifier" => "command", "verify" => [].freeze, "verify_timeout" => 1800,
                   "verify_keep" => ["target/"].freeze, "batch_cap" => 8, "rebuild_cap" => 3,
                   "check" => [].freeze, "lint" => [].freeze, "lint_files" => [].freeze, "check_retries" => 1 }.freeze

      KEYS = DEFAULTS.keys.freeze

      # `retain_days` starts at 1 because 0 would make a checkout reapable the
      # moment it was leased; `rebase_retries` starts at 0, which is how a
      # project turns worker self-sync off.
      RULES = {
        "retain_days" => Whole.new(floor: 1, unit: "days"),
        "rebase_retries" => Whole.new(floor: 0, unit: "retries"),
        "diff_algorithm" => OneOf.new(values: %w[histogram patience minimal myers].freeze),
        "conflict_style" => OneOf.new(values: %w[zdiff3 diff3 merge].freeze),
        "verifier" => OneOf.new(values: %w[command].freeze),
        "verify" => ArgList.new(what: "non-empty strings, the suite's argv", relative: false),
        "verify_timeout" => Whole.new(floor: 1, unit: "seconds"),
        "verify_keep" => ArgList.new(what: "non-empty relative paths", relative: true),
        "batch_cap" => Whole.new(floor: 1, unit: "entries"),
        "rebuild_cap" => Whole.new(floor: 0, unit: "rebuilds"),
        "check" => ArgList.new(what: "non-empty strings, the fast tier's test argv", relative: false),
        "lint" => ArgList.new(what: "non-empty strings, the fast tier's lint argv", relative: false),
        "lint_files" => ArgList.new(what: "non-empty globs, the files the lint may be handed", relative: false),
        "check_retries" => Whole.new(floor: 0, unit: "retries")
      }.freeze

      # The verb of `.lain/config.rb` that declares this table, as every refusal
      # here names it.
      TABLE = "`isolation`"

      # A hand-built table goes through the same rules as a file's rather than
      # being held as a Hash nothing validated.
      # @param value [Isolation, Object] a built value, or a table to read
      # @return [Isolation]
      def self.coerce(value) = value.is_a?(self) ? value : from(value, path: nil)

      # @param table [Object] whatever `raw["isolation"]` parsed to
      # @param path [String, nil] the config file, named by every refusal
      # @return [Isolation]
      def self.from(table, path:)
        table = {} if table.nil?
        raise Refusal.not_a_table(table, path:, table: TABLE) unless table.is_a?(Hash)

        unknown = table.keys - KEYS
        # A misspelt `retain_days` would otherwise run silently on the default.
        raise Refusal.unknown_keys(unknown, known: KEYS, path:, table: TABLE) unless unknown.empty?

        settings = DEFAULTS.merge(table)
        check!(settings, path:)
        new(**settings.transform_keys(&:to_sym))
      end

      # @param settings [Hash{String=>Object}] every key in {KEYS}
      # @param path [String, nil] the config file to name, nil for a value built directly
      # @raise [Config::Refusal] naming the first key whose value its rule refuses
      def self.check!(settings, path: nil)
        settings.each do |key, value|
          raise invalid_value(key, value, path:) unless RULES.fetch(key).admits?(value)
        end
      end

      # Its path is optional because {#initialize} raises this too, and a value
      # built directly names no config file.
      #
      # @return [Config::Refusal]
      def self.invalid_value(key, value, path: nil)
        rule = RULES.fetch(key)
        detail = rule.respond_to?(:problems) ? " (#{rule.problems(value).join("; ")})" : ""
        Refusal.new("#{key}: #{value.inspect} is not #{rule}#{detail}", path:, table: TABLE, key:, value:)
      end

      private_class_method :invalid_value

      def self.empty = EMPTY

      # The closed sets belong to the VALUE, so a hand-built table refuses as
      # loudly as a bad file; `.from`'s own check stays because only it can name
      # the file. Strings are interned and lists copied frozen because a parsed
      # one arrives unfrozen.
      def initialize(**settings)
        self.class.check!(settings.transform_keys(&:to_s))
        super(**settings.transform_values { |value| settle(value) })
      end

      private

      def settle(value)
        case value
        when String then -value
        when Array then value.map { |entry| settle(entry) }.freeze
        else value
        end
      end

      EMPTY = new(**DEFAULTS.transform_keys(&:to_sym))
      private_constant :EMPTY
    end
  end
end
