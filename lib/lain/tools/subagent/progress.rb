# frozen_string_literal: true

module Lain
  module Tools
    class Subagent < Tool
      # One dispatch's progress, told to the live views while the child is
      # still working: {Lineage} writes what the RECORD owes, this writes what
      # a watching human owes nothing to.
      #
      # A separate object from {Lineage} because the two answer to different
      # rules: those events are content-addressed and durable, and
      # {Telemetry::ChildProgress} holds why nothing may be added to them for a
      # status line. These records are neither -- a run that drops one has a
      # stale row and an intact record.
      #
      # IT WRAPS THE TURN OBSERVER rather than being told separately, because
      # the two facts must not drift: a row claiming three turns when the
      # session record holds four is worse than a row with no count. The wrap
      # tells the observer FIRST -- the durable promotion is the one that may
      # not be lost, and a scribe that refuses a turn must not leave a live row
      # claiming it landed.
      class Progress
        # A dispatch with nowhere to tell: an actor's launch, a spawn built
        # outside the one-shot path. The observer passes through untouched, so
        # no call site asks whether there is a progress to report to.
        module Null
          def self.watching(observer) = observer
        end

        # @param spawn [String] the `:spawn` digest this dispatch's rows hang on
        # @param tee [#<<] the live-view journal, where a fleet reader folds
        def initialize(spawn:, tee:)
          @spawn = spawn
          @tee = tee
          @turns = 0
        end

        # The standing half of the row, written once as the child is
        # dispatched: what it is for, and where its work is going.
        #
        # @param role [String] what the spawn is announced as
        # @param task [String] the prompt; the record clamps and scrubs it
        # @param worker [String, nil] the lease key, nil where no worker was
        #   minted
        # @return [self]
        def dispatched(role:, task:, worker:)
          @tee << Telemetry::ChildProgress.new(spawn: @spawn, role:, task_line: task, worker:, turns: @turns)
          self
        end

        # The child's turn observer, wrapped: every turn promoted to the record
        # also moves this spawn's row.
        #
        # @param observer [#call] the seam's observer, the scribe in a chat
        # @return [#call]
        def watching(observer)
          lambda do |turn|
            observer.call(turn)
            @turns += 1
            @tee << Telemetry::ChildProgress.new(spawn: @spawn, turns: @turns, head: turn.digest)
          end
        end
      end
    end
  end
end
