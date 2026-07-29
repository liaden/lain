# frozen_string_literal: true

module Lain
  module Telemetry
    module Guards
      # A handback record must name the worker whose work it disposed of and
      # land on one of the outcomes the operation can reach. The kinds are
      # {Isolation::Worktree::Handback::Outcome::KINDS}, held verbatim here
      # rather than referenced: this Guard's class body evaluates at
      # telemetry load time, before the isolation/ unit loads (the same
      # load-order reason {SeamDecision} holds {Plan::SIZES} verbatim).
      class Handback < Guard
        attribute :worker_key
        attribute :outcome
        validates :worker_key, presence: { message: "must name the worker handed back, got nil" }
        validates :outcome, inclusion: { in: %i[nothing_to_do merged conflicted declined failed],
                                         message: "must be one of nothing_to_do/merged/conflicted/declined/" \
                                                  "failed, got %<value>s" }
      end
    end

    # What became of one worker's committed work when its isolated checkout was
    # handed back. `worker_key` is the STRING form of the caller's `worker_id`,
    # the same self-describing key {IsolationLease} carries, so the two join on
    # one value: N acquire/release pairs and what each one's work was worth.
    # `outcome` is the {Isolation::Worktree::Handback::Outcome} kind, and `ref`
    # names where the commits are anchored -- nil when nothing was written
    # (nothing to hand back, or a failure before the ref write), absence being
    # the signal exactly as it is on the Outcome itself.
    #
    # A REF, never a path: `refs/lain/worker/<worker>` is repo-relative by
    # construction, so this record can never leak a filesystem path outside the
    # repository, and it deliberately carries no {Isolation::WorkerEnv} -- an
    # env is a live resource handle full of credentials, not attribution.
    #
    # Emitted by {Isolation::Worktree::Handback} itself rather than by a
    # decorator: handback is a one-shot operation whose whole product IS the
    # outcome, so there is no forwarding duck to wrap the way
    # {Isolation::Journal} wraps a backend.
    Handback = Data.define(:worker_key, :outcome, :ref) do
      include Journalable

      def initialize(worker_key:, outcome:, ref: nil)
        outcome = outcome.to_sym
        Guards::Handback.check!(worker_key:, outcome:)

        super(worker_key: worker_key.to_s.dup.freeze, outcome:, ref: ref&.dup&.freeze)
      end
    end
  end
end
