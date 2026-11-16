# frozen_string_literal: true

module Lain
  class Config
    Github = Data.define(:account, :orgs, :roots, :keywords, :paths, :since_days)

    # The `github` table, which either config file may declare: the account gh
    # acts as, and the filters that pick which review requests matter. A table
    # read from one file leaves what it does not say as nil, so {.resolve} can
    # tell "unset" from "set to empty" when it layers the files.
    class Github
      TABLE = "`github`"
      KEYS = %w[account orgs roots keywords paths since_days].freeze
      ENV_ACCOUNT = "LAIN_GH_ACCOUNT"
      DEFAULT_SINCE_DAYS = 14
      LISTS = %w[orgs roots keywords].freeze

      # @param table [Hash{String=>Object}, nil]
      # @param path [String, nil] the config file and line to name
      # @return [Github] fields the table leaves out are nil
      # @raise [Refusal] for an unknown key or a value of the wrong type
      def self.from(table, path:)
        table = Table.read(table, path:, name: TABLE, keys: KEYS)
        lists = LISTS.to_h { |key| [key, strings(table[key], key, path)] }
        new(account: account(table["account"], path), orgs: lists["orgs"],
            roots: lists["roots"]&.map { |root| -File.expand_path(root) }&.freeze,
            keywords: lists["keywords"], paths: patterns(table["paths"], path),
            since_days: days(table["since_days"], path))
      end

      # @return [Github] every field unset
      def self.empty = from(nil, path: nil)

      # @param project [Github] the project file's table
      # @param user [Github] the user file's table
      # @param env [Hash{String=>String}]
      # @return [Github] the environment's account, else the project's field, else the user's, else the default
      def self.resolve(project:, user:, env:)
        layered = members.to_h do |field|
          [field, project.public_send(field).nil? ? user.public_send(field) : project.public_send(field)]
        end
        layered[:account] = env[ENV_ACCOUNT] unless env[ENV_ACCOUNT].to_s.strip.empty?
        defaults.with(**layered.compact)
      end

      def self.defaults
        new(account: nil, orgs: [].freeze, roots: [].freeze, keywords: [].freeze, paths: [].freeze,
            since_days: DEFAULT_SINCE_DAYS)
      end
      private_class_method :defaults

      def self.refuse(message, path, key, value)
        raise Refusal.new("#{key} #{message}, got #{value.inspect}", path:, table: TABLE, key:, value:)
      end
      private_class_method :refuse

      def self.account(value, path)
        return value if value.nil?

        refuse("must be a non-blank string", path, "account", value) unless value.is_a?(String) && !value.strip.empty?
        -value.strip
      end
      private_class_method :account

      def self.strings(value, key, path)
        return value if value.nil?

        refuse("must be a list of non-blank strings", path, key, value) unless strings?(value)
        value.map { |item| -item.strip }.freeze
      end
      private_class_method :strings

      def self.strings?(value) = value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.strip.empty? }
      private_class_method :strings?

      def self.patterns(value, path)
        return value if value.nil?

        refuse("must be a list of Regexp", path, "paths", value) unless value.is_a?(Array) && value.all?(Regexp)
        value.map { |pattern| Ractor.make_shareable(pattern) }.freeze
      end
      private_class_method :patterns

      def self.days(value, path)
        return value if value.nil?

        refuse("must be a whole number of days, 1 or more", path, "since_days", value) unless valid_days?(value)
        value
      end
      private_class_method :days

      def self.valid_days?(value) = value.is_a?(Integer) && value.positive?
      private_class_method :valid_days?
    end
  end
end
