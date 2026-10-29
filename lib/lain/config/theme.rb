# frozen_string_literal: true

module Lain
  class Config
    Theme = Data.define(:tokens)

    # The `theme` table of the user's config.rb: which Pastel styles a token
    # wears. Only the user's file may declare it, because a colour is a
    # property of the person's terminal, not of a project.
    class Theme
      TABLE = "`theme`"

      # @param table [Hash{String=>Object}, nil] token name to style names
      # @param path [String, nil] the config file and line to name
      # @return [Theme] every token, the declared ones recoloured
      # @raise [Refusal] for an unknown token, or a style Pastel cannot apply
      def self.from(table, path:)
        table = {} if table.nil?
        raise Refusal.not_a_table(table, path:, table: TABLE) unless table.is_a?(Hash)

        refuse_unknown_tokens(table.keys - defaults.keys.map(&:to_s), path:)
        declared = table.to_h { |token, styles| [token.to_sym, styles_of(token, styles, path:)] }
        new(tokens: defaults.merge(declared).freeze)
      end

      # @return [Theme] every token at its default
      def self.empty = from(nil, path: nil)

      def self.defaults = Frontend::Theme::DEFAULT_TOKENS

      def self.refuse_unknown_tokens(unknown, path:)
        return if unknown.empty?

        detail = "has no tokens #{unknown.map(&:inspect).join(", ")}; known tokens: #{defaults.keys.join(", ")}"
        raise Refusal.new(detail, path:, table: TABLE, key: unknown)
      end
      private_class_method :refuse_unknown_tokens

      def self.styles_of(token, styles, path:)
        unless names?(styles)
          raise refusal(token, styles, "must be a list of style names, got #{styles.inspect}",
                        path:)
        end

        names = styles.map(&:to_sym)
        unknown = names - Frontend::Theme::STYLES
        unless unknown.empty?
          raise refusal(token, styles, "has no style #{unknown.first.to_s.inspect}; known styles: " \
                                       "#{Frontend::Theme::STYLES.join(", ")}", path:)
        end

        names.freeze
      end
      private_class_method :styles_of

      def self.names?(styles)
        styles.is_a?(Array) && styles.all? { |style| style.is_a?(String) || style.is_a?(Symbol) }
      end
      private_class_method :names?

      def self.refusal(token, styles, detail, path:)
        Refusal.new("#{token} #{detail}", path:, table: TABLE, key: token.to_s, value: styles)
      end
      private_class_method :refusal
    end
  end
end
