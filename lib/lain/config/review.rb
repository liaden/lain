# frozen_string_literal: true

module Lain
  class Config
    Review = Data.define(:model)

    # The `review` table: the model a document review runs under, when it
    # should not be the author's.
    class Review
      TABLE = "`review`"
      KEYS = %w[model].freeze

      # The model a review runs under, beside the author's it was chosen against.
      #
      # @!attribute [r] model
      #   @return [String] the model the review runs under
      # @!attribute [r] author
      #   @return [String] the model that wrote what is reviewed
      Choice = Data.define(:model, :author)

      # @param table [Hash{String=>Object}, nil]
      # @param path [String, nil] the config file and line to name
      # @return [Review]
      # @raise [Refusal] for an unknown key, or a model that is not a non-blank string
      def self.from(table, path:)
        model = Table.read(table, path:, name: TABLE, keys: KEYS)["model"]
        unless model.nil? || (model.is_a?(String) && !model.strip.empty?)
          raise Refusal.new("model must be a non-blank string, got #{model.inspect}", path:, table: TABLE,
                                                                                      key: "model", value: model)
        end

        new(model: model && -model.strip)
      end

      # @return [Review] the one that names no model
      def self.empty = from(nil, path: nil)

      # @param author [String] the model that wrote what is reviewed
      # @return [Choice] the configured model, else the author's
      def choose(author:) = Choice.new(model: model || author, author:)
    end
  end
end
