# frozen_string_literal: true

module Lain
  class Agent
    # The messages of the last head rendered, so the next render materialises
    # only the turns after it. A head that no longer descends from it (a rewind,
    # a checkout, a fold) is walked whole: a prefix is extended, never spliced.
    RenderedPrefix = Data.define(:head_digest, :messages) do
      def self.none = new(head_digest: nil, messages: [].freeze)

      # @param timeline [#head_digest, #messages]
      # @return [RenderedPrefix] the prefix for the timeline's head
      def over(timeline)
        head = timeline.head_digest
        return self if head == head_digest

        with(head_digest: head, messages: timeline.messages(after: head_digest, onto: messages))
      end
    end
  end
end
