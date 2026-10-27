# frozen_string_literal: true

module Lain
  module Bench
    class ApprovalReplay
      # Who answers a call the replay parks. `recorded` answers what the session's human answered
      # for that call, in order; `perfect` approves everything, which flatters a mode and is
      # reported beside the recorded one for that reason.
      #
      # A park the session has no answer for -- the call was decided by a rung above the queue
      # live -- is refused, under automatic authority so no rung remembers it as a person's no.
      class Approver
        SURFACE = "approval-replay"

        # @param kind [Symbol] one of {APPROVERS}
        # @param calls [Enumerable<Call>]
        # @return [Approver]
        def self.for(kind, calls) = new(kind, decisions: calls.to_h { [_1.tool_use_id, _1.decisions] })

        # @param kind [Symbol, String] one of {APPROVERS}
        # @param decisions [Hash{String=>Array<String>}] tool_use id => the verdicts given, in order
        # @param surface [String] who an answer is journaled as coming from
        # @raise [ArgumentError] for any other kind
        def initialize(kind, decisions: {}, surface: SURFACE)
          @kind = kind.to_sym
          @surface = surface
          raise ArgumentError, "approver is #{APPROVERS.join(" or ")}, not #{kind}" unless APPROVERS.include?(@kind)

          @decisions = decisions.transform_values(&:dup)
          @prompted = Set.new
          @unanswered = Set.new
        end

        # @param pending [Approval::Parked::Queue::Pending]
        # @return [void]
        def answer(pending)
          id = pending.tool_use_id
          @prompted << id
          return pending.approve(surface: @surface, authority: :human) if verdict(id) == "approve"
          return pending.deny(surface: @surface) if @unanswered.include?(id)

          pending.deny(surface: @surface, authority: :human)
        end

        def prompted?(tool_use_id) = @prompted.include?(tool_use_id)

        def unanswered?(tool_use_id) = @unanswered.include?(tool_use_id)

        private

        def verdict(id)
          return "approve" if @kind == :perfect

          given = @decisions.fetch(id, []).shift
          @unanswered << id unless given
          given
        end
      end
    end
  end
end
