# frozen_string_literal: true

module Lain
  module Memory
    Author = Data.define(:kind, :spawn)

    # Who wrote a memory row, stamped by lain and never taken from the model.
    # A clerk's author cites the lineage spawn it distilled, so a row can be
    # traced back to its evidence.
    class Author
      KINDS = %w[chat clerk].freeze

      def self.chat = new(kind: "chat", spawn: nil)

      def self.clerk(spawn:) = new(kind: "clerk", spawn:)

      # A row with no author predates the stamp and was the chat's.
      def self.from(record)
        return chat if record.nil?
        raise ArgumentError, "an author record must be a hash, got #{record.inspect}" unless record.is_a?(Hash)

        new(kind: record.fetch("kind"), spawn: record["spawn"])
      end

      def initialize(kind:, spawn: nil)
        unless KINDS.include?(kind)
          raise ArgumentError,
                "author kind must be one of #{KINDS.join(", ")}, got #{kind.inspect}"
        end
        raise ArgumentError, "a clerk author must cite the spawn it read" if kind == "clerk" && spawn.to_s.empty?
        raise ArgumentError, "a chat author cites no spawn" if kind == "chat" && !spawn.nil?

        super(kind: -kind, spawn: spawn&.then { |value| -value.to_s })
      end

      def chat? = kind == "chat"

      def to_h = spawn.nil? ? { "kind" => kind } : { "kind" => kind, "spawn" => spawn }

      def to_s = chat? ? "chat" : "clerk (spawn #{spawn})"
    end
  end
end
