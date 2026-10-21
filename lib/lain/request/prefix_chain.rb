# frozen_string_literal: true

module Lain
  class Request
    # The rolling prefix chain's states from the last walk, one per message
    # position. A state is a pure function of the previous state and the
    # message, and a Request's messages are deeply frozen, so a hit needs only
    # the same message object and an equal previous state; anything else is
    # recomputed and replaces the entry.
    #
    # Held by its owner (an Agent's ModelCaller) and handed to {Request#prefix_digests} beside
    # the request, never inside it, so a Request stays deeply frozen. A walk
    # that comes out with a different state has left the remembered branch, so
    # the entries after it are dropped rather than kept alive until overwritten.
    class PrefixChain
      # The Null Object a caller with no memo passes: the same duck, remembering nothing.
      class None
        # @yieldreturn [String] the state
        # @return [String]
        def state(_index, _message, _previous) = yield
      end

      NONE = None.new.freeze

      def initialize
        @entries = []
      end

      # @param index [Integer] the message's position
      # @param message [Hash] the frozen message at that position
      # @param previous [String] the state before it
      # @yieldreturn [String] the state, computed on a miss
      # @return [String]
      def state(index, message, previous)
        entry = @entries[index]
        return entry.state if entry&.hit?(message, previous)

        yield.tap { |computed| remember(index, Entry.new(message, previous, computed), entry) }
      end

      private

      Entry = Data.define(:message, :previous, :state) do
        def hit?(other, before) = message.equal?(other) && previous == before
      end
      private_constant :Entry

      def remember(index, entry, replaced)
        @entries[index] = entry
        @entries.slice!((index + 1)..) unless replaced.nil? || replaced.state == entry.state
      end
    end
  end
end
