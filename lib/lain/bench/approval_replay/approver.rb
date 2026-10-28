# frozen_string_literal: true

module Lain
  module Bench
    class ApprovalReplay
      # Who answers a call the replay parks. `recorded` answers what the session's human answered
      # for that call, in order. `approve_all` approves everything, the floor for harmful calls
      # stopped. `perfect` answers each call by its label: it denies a harmful one and approves
      # the rest, so what it stops is the most any answerer could add to a mode.
      #
      # A park the session has no answer for -- the call was decided by a rung above the queue
      # live -- is refused, under automatic authority so no rung remembers it as a person's no.
      class Approver
        SURFACE = "approval-replay"

        # @param kind [Symbol] one of {APPROVERS}
        # @param calls [Enumerable<Call>]
        # @param labels [Labels] what `perfect` reads; the digests are the calls' own
        # @return [Approver]
        def self.for(kind, calls, labels: Labels::NONE)
          new(kind, decisions: calls.to_h { [_1.tool_use_id, _1.decisions] },
                    labelled: calls.to_h { [_1.tool_use_id, labels.fetch(_1.digest)] })
        end

        # @param kind [Symbol, String] one of {APPROVERS}
        # @param decisions [Hash{String=>Array<String>}] tool_use id => the verdicts given, in order
        # @param labelled [Hash{String=>String, nil}] tool_use id => the call's label, for `perfect`
        # @param surface [String] who an answer is journaled as coming from
        # @raise [ArgumentError] for any other kind
        def initialize(kind, decisions: {}, labelled: {}, surface: SURFACE)
          @kind = kind.to_sym
          @surface = surface
          raise ArgumentError, "approver is #{APPROVERS.join(" or ")}, not #{kind}" unless APPROVERS.include?(@kind)

          @labelled = labelled
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
          return "approve" if @kind == :approve_all
          return by_label(id) if @kind == :perfect

          given = @decisions.fetch(id, []).shift
          @unanswered << id unless given
          given
        end

        # An unlabelled call has no right answer to give, so it goes unanswered rather than guessed.
        def by_label(id)
          label = @labelled[id]
          @unanswered << id unless label
          label && (label == "harmful" ? "deny" : "approve")
        end
      end
    end
  end
end
