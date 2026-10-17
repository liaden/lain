# frozen_string_literal: true

module Lain
  SearchRules = Data.define(:include, :limit)

  # The `search` table: the ignored paths a project wants searched anyway, and
  # how much one walk may cost.
  #
  #     search include: %w[planning/notes/*.md], max_entries: 50_000
  #
  # Reopened because a constant written in the `Data.define` block would land
  # on {Lain}. Read by {Config.search} rather than {Config.load}, for the
  # reason {Shell::Exclusions} carries: a typo must refuse loudly.
  #
  # An include can only widen what a search reads, and a glob that climbs out
  # of the project would widen it past the boundary the config governs, so such
  # a glob is refused rather than clamped.
  #
  # @!attribute include
  #   @return [Array<String>] globs, relative to the repository top, naming
  #     ignored files a search should still read
  # @!attribute limit
  #   @return [Tool::Bounds::WalkLimit] what one walk may list and read
  class SearchRules
    INCLUDE = "include"
    MAX_ENTRIES = "max_entries"
    MAX_BYTES = "max_bytes"
    KEYS = [INCLUDE, MAX_ENTRIES, MAX_BYTES].freeze
    DRIVE = /\A[A-Za-z]:/
    private_constant :DRIVE

    # The verb of `.lain/config.rb` that declares this table, as every refusal
    # here names it.
    TABLE = "`search`"

    # @param table [Object] whatever `raw["search"]` parsed to; nil when absent
    # @param path [String, nil] the config file, named in every refusal
    # @return [SearchRules]
    # @raise [Config::Refusal]
    def self.from(table, path: nil)
      table = {} if table.nil?
      raise Config::Refusal.not_a_table(table, path:, table: TABLE) unless table.is_a?(Hash)

      unknown = table.keys - KEYS
      raise Config::Refusal.unknown_keys(unknown, known: KEYS, path:, table: TABLE) if unknown.any?

      globs = table.fetch(INCLUDE, [])
      check_globs!(globs, path:)
      new(include: globs.map { _1.dup.freeze }.freeze, limit: limit_from(table, path:))
    end

    # @return [SearchRules] the value an absent table yields: nothing
    #   re-included, the default limits
    def self.empty = EMPTY

    def self.check_globs!(globs, path:)
      raise refusal("#{INCLUDE} is a list of globs, got #{globs.class}", globs, path:) unless globs.is_a?(Array)

      globs.each do |glob|
        detail = glob_problem(glob)
        raise refusal("#{INCLUDE} #{glob.inspect} #{detail}", glob, path:) if detail
      end
    end

    def self.glob_problem(glob)
      return "must be a string" unless glob.is_a?(String)
      return "must not be blank" if Blankness.blank?(glob)
      return "must be matchable text" unless Sensitivity.readable?(glob)
      return "leaves the project; include globs stay under the project root" if leaves_project?(glob)
      return "has a . or empty segment, which no listed path can match" if never_matches?(glob)

      nil
    end

    # A backslash and a brace each hide a separator or a segment from a plain
    # split, so both read as separators here: refusing too much is safe, and
    # reading `{..,a}` as a name is how a glob would climb out.
    def self.leaves_project?(glob)
      glob.start_with?("/", "~") || glob.match?(DRIVE) || glob.gsub(/[\\{},]/, "/").split("/").include?("..")
    end

    def self.never_matches?(glob) = glob.split("/", -1).any? { _1.empty? || _1 == "." }

    def self.limit_from(table, path:)
      default = Tool::Bounds::WalkLimit::DEFAULT
      Tool::Bounds::WalkLimit.new(entries: count(table, MAX_ENTRIES, default.entries, path:),
                                  bytes: count(table, MAX_BYTES, default.bytes, path:))
    end

    def self.count(table, key, default, path:)
      value = table.fetch(key, default)
      return value if value.is_a?(Integer) && value.positive?

      raise refusal("#{key} must be a positive integer, got #{value.inspect}", value, path:, key:)
    end

    def self.refusal(detail, value, path:, key: INCLUDE)
      Config::Refusal.new(detail, path:, table: TABLE, key:, value:)
    end

    private_class_method :check_globs!, :glob_problem, :leaves_project?, :never_matches?, :limit_from, :count, :refusal

    EMPTY = new(include: [].freeze, limit: Tool::Bounds::WalkLimit::DEFAULT).freeze
    private_constant :EMPTY
  end
end
