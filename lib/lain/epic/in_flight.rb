# frozen_string_literal: true

module Lain
  module Epic
    # Puts an approved plan's issue in flight -- the one issue transition an
    # approval writes, whichever surface approved it. Every surface reaches it
    # through {Advance}, which asks {.starts?} whether an approval starts an
    # issue, so the trigger rule and the move live in one place.
    #
    # Only a PENDING issue moves: re-approving a revised plan is not a second
    # start, and a plan does not restart a done or abandoned issue. That also
    # makes it safe to run over a STANDING approval, which is how a re-submit
    # repairs a process that died between the approval and the move.
    #
    # AT LEAST ONCE, not exactly once: the status is read and then the move is
    # written, and the journal has no compare-and-append. Two processes that
    # both read pending both write the move; the fold reads the later record,
    # so the issue is in flight either way.
    class InFlight
      PENDING = "pending"
      MOVED_TO = "in_flight"
      STARTING_STAGE = "issue_plan"

      # An approved issue plan that names its issue. A plan approval recorded
      # before gates named their issue names none, and moving an issue it may
      # not have meant is worse than moving none.
      def self.starts?(approved:, stage:, issue_id:)
        approved == true && stage.to_s == STARTING_STAGE && !issue_id.nil?
      end

      # @param scribe [Scribe] the epic tier's one writer of a transition
      # @param progress [#call] answers the epic's {Progress}, asked only when
      #   the move is attempted
      # @param issue_id [String, nil] the issue the approved plan is for; nil
      #   for an epic-wide stage, which never asks
      def initialize(scribe:, progress:, issue_id:)
        @scribe = scribe
        @progress = progress
        @issue_id = issue_id
      end

      # @return [String] what moved, for the approving surface's report
      def call
        status = @progress.call.status(@issue_id)
        return "issue #{@issue_id} is #{status} -- nothing moved" unless status == PENDING

        @scribe.issue_moved(@issue_id, from: PENDING, to: MOVED_TO)
        "issue #{@issue_id} moved #{PENDING} -> #{MOVED_TO}"
      end
    end
  end
end
