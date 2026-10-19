# frozen_string_literal: true

module Lain
  class Channel
    # Re-aliases `<<` because Channel's `alias << push` early-binds to the parent.
    class Tee < Channel
      EVERY = ->(_event) { true }

      # @param sink [#<<] receives each event the predicate accepts
      # @param only [#call] predicate on the event; the channel keeps every event regardless
      def initialize(sink, only: EVERY)
        super()
        @sink = sink
        @only = only
      end

      def push(event)
        @sink << event if @only.call(event)
        super
      end
      alias << push
    end
  end
end
