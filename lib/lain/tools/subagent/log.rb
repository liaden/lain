# frozen_string_literal: true

module Lain
  module Tools
    class Subagent < Tool
      # The append-only, ordered read-side a mailbox {Event::Projection} folds.
      # The shared {Store} is a digest->object map with no order, so it cannot
      # present a recipient's messages as a SEQUENCE; this preserves emission
      # order so the projection can. Append-only by construction -- no delete,
      # no pop -- which is what keeps a mailbox a pure FOLD rather than a
      # consumed queue: reading it twice yields the same messages.
      #
      # Written once, by {Lineage}, as every attributed event is put. The Null
      # instance drops those appends, because a one-shot spawn is consumed
      # within its dispatch and nobody folds its stream.
      class Log
        include Enumerable

        def initialize
          @events = []
        end

        def <<(event)
          @events << event
          self
        end

        def each(&block) = @events.each(&block)

        # Appends vanish, so {Lineage} stays uniform without a one-shot paying
        # for an event list nothing will fold. A FULL Null Object, not just a
        # `<<` sink: it enumerates as empty, so a caller folding it gets the
        # honest answer rather than a NoMethodError.
        module Null
          extend Enumerable

          def self.<<(_event) = self

          def self.each
            return enum_for(:each) unless block_given?

            self
          end
        end
      end
    end
  end
end
