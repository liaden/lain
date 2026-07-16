# frozen_string_literal: true

module Lain
  module Tools
    class Subagent < Tool
      # The append-only, ordered read-side of the orchestration event stream --
      # the log a mailbox {Event::Projection} folds. The shared {Store} is a
      # digest->object map with no order, so it cannot present a recipient's
      # messages as a sequence; this preserves emission order so the projection
      # can. Append-only by construction (no delete, no pop), which is exactly
      # what keeps a mailbox a pure fold rather than a consumed queue: reading it
      # a second time yields the same messages.
      #
      # It is the read-side an ORCHESTRATOR holds -- the parent folds it into its
      # prompt (Context::Mailbox), an actor folds it to find its own inbound. It
      # is written once, by {Lineage}, as every attributed event is put; a Null
      # instance (the one-shot default) drops those appends, because a one-shot
      # spawn is consumed within its dispatch and no one folds its stream.
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

        # The one-shot default: appends vanish, so {Lineage} stays uniform
        # (always `@log << event`) without a one-shot paying for an event list
        # nothing will fold. A full Null Object, not just a `<<` sink: it also
        # enumerates as empty, so a caller folding it (a Projection over
        # `log.to_a`) gets the honest answer rather than a NoMethodError.
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
