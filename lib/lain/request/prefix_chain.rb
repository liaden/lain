# frozen_string_literal: true

require "json"

module Lain
  class Request
    # The rolling prefix chain's states from the last walk: the seed over model,
    # tools and system, then one state per message position. A state is a pure
    # function of the previous state and the marker-stripped message, so a hit
    # needs only a message with the same bytes and an equal previous state. A
    # message that misses but strips to the same bytes, as one a cache marker
    # moved on or off does, keeps its state without a digest. "The same bytes"
    # is {Canonical::Equality.same?}, never `==`.
    #
    # Held by its owner (an Agent, or one bench replay) and handed to
    # {Request.new} beside the request, never inside it, so a Request stays
    # deeply frozen. A walk that comes out with a different state has left the
    # remembered branch, so the entries after it are dropped rather than kept
    # alive until overwritten.
    class PrefixChain
      # One position's state, and the markers its value gave up to reach it: the
      # digest tells requests apart by those markers, and the state must not.
      # `stripped` is the message itself unless it carried a marker. A seed's
      # `message` is its 3 inputs, and its `previous` nil.
      Entry = Data.define(:message, :stripped, :previous, :state, :markers) do
        # @return [Entry] this entry's state for `message`, or a freshly digested one
        def restated(message, previous)
          previous == self.previous ? moved(message) : Entry.rolled(message, previous)
        end

        # A message is a Request member, normalized when the Request was built,
        # and stripping only drops keys, so its dump is already Canonical's;
        # Canonical.digest would normalize it a second time.
        #
        # @return [Entry] the state after `message`, digested
        def self.rolled(message, previous)
          return marked(message, previous) if Request.marked?(message)

          new(message:, stripped: message, previous:, markers: NO_MARKERS, state: digested(message, previous))
        end

        def self.marked(message, previous)
          stripped, markers = Request.without_markers(message)
          new(message:, stripped:, previous:, markers:, state: digested(stripped, previous))
        end
        private_class_method :marked

        def self.digested(stripped, previous) = Canonical.digest_bytes(JSON.generate([previous, stripped]))

        private

        # The same position after the same state: a cache marker that moved on or
        # off the message leaves its stripped bytes, and so its state, as they were.
        def moved(message)
          stripped, markers = Request.without_markers(message)
          return with(message:, stripped:, markers:) if Canonical::Equality.same?(stripped, self.stripped)

          Entry.new(message:, stripped:, previous:, markers:, state: Entry.digested(stripped, previous))
        end
      end

      NO_MARKERS = [].freeze
      private_constant :NO_MARKERS

      class << self
        # @return [Entry] state_0
        def seeded(model, tools, system)
          fixed, markers = Request.without_markers({ "tools" => tools, "system" => system })
          Entry.new(message: [model, tools, system].freeze, stripped: fixed, previous: nil, markers:,
                    state: Canonical.digest("model" => model, "tools" => fixed["tools"], "system" => fixed["system"]))
        end

        # @return [Entry] the state after `message`
        def rolled(message, previous) = Entry.rolled(message, previous)

        # @return [Array] `markers`, grown by the entry's markers at their wire paths
        def collect(markers, entry, index)
          entry.markers.each { |path, key, value| markers << [["messages", index, *path], key, value] }
          markers
        end
      end

      # Its nil `previous` matches no walk's, so every message restated from it is digested.
      UNSEEN = Entry.new(message: nil, stripped: nil, previous: nil, state: nil, markers: NO_MARKERS)
      private_constant :UNSEEN

      # The Null Object a caller with no memo passes: the same duck, remembering nothing.
      class None
        def seed(...) = PrefixChain.seeded(...)

        def entry(_index, message, previous) = PrefixChain.rolled(message, previous)

        # Only a marked message needs an Entry, for its markers; the rest are digested bare.
        #
        # @return [Array(String, Array)] the rolled state and the markers
        def roll(messages, seed)
          state = seed.state
          markers = seed.markers.dup
          messages.each_with_index do |message, index|
            if Request.marked?(message)
              entry = Entry.rolled(message, state)
              state = entry.state
              PrefixChain.collect(markers, entry, index)
            else
              state = Entry.digested(message, state)
            end
          end
          [state, markers]
        end
      end

      NONE = None.new.freeze

      def initialize
        @seed = nil
        @entries = []
      end

      # Compared by value, since a render builds its tool schemas afresh; a
      # changed seed drops every entry.
      #
      # @return [Entry] state_0, memoised against its 3 inputs
      def seed(model, tools, system)
        return @seed if @seed && seeded_on?(model, tools, system)

        PrefixChain.seeded(model, tools, system).tap do |fresh|
          @entries.clear unless @seed&.state == fresh.state
          @seed = fresh
        end
      end

      # @return [Array(String, Array)] the rolled state and the markers
      def roll(messages, seed)
        state = seed.state
        markers = seed.markers.dup
        # A local rather than `inject`: its destructured pair is an allocation per
        # message, a third of a warm 10,000-message walk.
        messages.each_with_index do |message, index|
          entry = entry(index, message, state)
          state = entry.state
          PrefixChain.collect(markers, entry, index)
        end
        [state, markers]
      end

      # @param index [Integer] the message's position
      # @param message [Hash] the frozen message at that position, in canonical wire form
      # @param previous [String] the state before it
      # @return [Entry]
      def entry(index, message, previous)
        remembered = @entries[index]
        return remembered if remembered && remembered.previous == previous && same?(remembered.message, message)

        (remembered || UNSEEN).restated(message, previous).tap { |computed| remember(index, computed, remembered) }
      end

      private

      # Input by input, so a schema or system handed over again as the same
      # object hits on identity and is never dumped.
      def seeded_on?(*inputs) = inputs.each_with_index.all? { |input, at| same?(@seed.message[at], input) }

      # The same object for a live conversation, or the same bytes for one
      # rebuilt from a journal, which needs neither a strip nor a digest.
      def same?(remembered, message) = remembered.equal?(message) || Canonical::Equality.same?(remembered, message)

      def remember(index, entry, replaced)
        @entries[index] = entry
        @entries.slice!((index + 1)..) unless replaced.nil? || replaced.state == entry.state
      end
    end
  end
end
