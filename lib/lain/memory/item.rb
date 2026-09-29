# frozen_string_literal: true

module Lain
  module Memory
    # A frozen unit of memory: a caller-chosen id, a one-line description, and
    # a body. Its digest is the content address of those three fields, plus the
    # author when it is not the chat, so a Store dedupes rewrites of identical
    # content for free.
    #
    # The one-line id and description are structural, not advisory: a Manifest
    # renders one line per item, and any vertical whitespace would let one item
    # read as two.
    class Item
      include ContentAddressed
      include Declarative

      # [[:space:]] is Unicode-aware where String#strip is ASCII-only: an
      # NBSP-only id must still count as blank. Private: the rule is exposed
      # as the .blank_id? predicate below, not as a regex callers match
      # against directly.
      BLANK = /\A[[:space:]]*\z/
      private_constant :BLANK

      # Ruby's \R already covers \n, \r, \r\n, \v, \f and NEL; \v and
      # U+2028/U+2029 are spelled out so the invariant survives a regex-engine
      # subtlety rather than depending on one.
      LINE_BREAK = /\R|[\v  ]/
      private_constant :LINE_BREAK

      attr_reader :id, :description, :body, :author, :digest

      # The blank-id rule as a class-level predicate: directly testable
      # (including the NBSP-only Unicode edge) without constructing a whole
      # Item just to provoke the ArgumentError.
      def self.blank_id?(id)
        id.to_s.match?(BLANK)
      end

      # Only the id gets the blank check: an item that cannot be addressed is a
      # defect, where an empty description is merely a pointless manifest line.
      # Both rules cite the constants above rather than restating them, so the
      # declaration and {.blank_id?} cannot drift into two answers.
      declare do
        attribute :id, :lain_canonical
        attribute :description, :lain_canonical
        attribute :body, :lain_canonical
        validates :id, format: { without: BLANK, message: "must not be blank" }
        validates :id, :description, format: { without: LINE_BREAK, message: "must be one line" }
      end

      # The keywords stay spelled out rather than collected as `**attrs`: a
      # declaration has no arity, so a forgotten `body:` would settle to nil and
      # be digested instead of refused.
      def initialize(id:, description:, body:, author: Author.chat)
        @id, @description, @body = self.class.settle!(id:, description:, body:).values_at(:id, :description, :body)
        @author = author
        @digest = Canonical.digest(payload)
        freeze
      end

      # The exact structure that was hashed. Also what a Journal writes. The
      # chat's authorship is omitted so every row and record written before
      # authors existed keeps the digest it was stored under.
      def payload
        base = { "id" => id, "description" => description, "body" => body }
        author.chat? ? base : base.merge("author" => author.to_h)
      end

      def to_s
        "#<Lain::Memory::Item #{id} #{digest[0, 19]}...>"
      end
      alias inspect to_s
    end
  end
end
