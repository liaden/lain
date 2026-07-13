# frozen_string_literal: true

module Lain
  module Memory
    # A frozen unit of memory: a caller-chosen id, a one-line description, and
    # a body. Its digest is the content address of those three fields, so a
    # Store dedupes rewrites of identical content for free.
    #
    # The one-line id and description are structural, not advisory: a Manifest
    # renders one line per item, and any vertical whitespace would let one item
    # read as two.
    class Item
      include ContentAddressed

      # [[:space:]] is Unicode-aware where String#strip is ASCII-only: an
      # NBSP-only id must still count as blank.
      BLANK = /\A[[:space:]]*\z/

      # Ruby's \R already covers \n, \r, \r\n, \v, \f and NEL; \v and
      # U+2028/U+2029 are spelled out so the invariant survives a regex-engine
      # subtlety rather than depending on one.
      LINE_BREAK = /\R|[\v  ]/

      attr_reader :id, :description, :body, :digest

      def initialize(id:, description:, body:)
        @id = checked_id(Canonical.normalize(id))
        @description = one_line("description", Canonical.normalize(description))
        @body = Canonical.normalize(body)
        @digest = Canonical.digest(payload)
        freeze
      end

      # The exact structure that was hashed. Also what a Journal writes.
      def payload
        { "id" => id, "description" => description, "body" => body }
      end

      def to_s
        "#<Lain::Memory::Item #{id} #{digest[0, 19]}...>"
      end
      alias inspect to_s

      private

      # An item that cannot be addressed is a defect; an empty description is
      # merely a pointless manifest line, so only the id gets the blank check.
      def checked_id(id)
        raise ArgumentError, "id must not be blank, got #{id.inspect}" if id.match?(BLANK)

        one_line("id", id)
      end

      def one_line(field, value)
        raise ArgumentError, "#{field} must be one line, got #{value.inspect}" if value.match?(LINE_BREAK)

        value
      end
    end
  end
end
