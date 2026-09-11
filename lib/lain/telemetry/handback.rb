# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A handback record must name the worker whose work it disposed of and
      # land on one of the outcomes the operation can reach. The kinds are
      # {Isolation::Worktree::Handback::Outcome::KINDS}, held verbatim here
      # rather than referenced: this carrier's class body evaluates at
      # telemetry load time, before the isolation/ unit loads (the same
      # load-order reason {SeamDecision} holds {Plan::SIZES} verbatim).
      class Handback < Declarative::Carrier
        attribute :worker_key
        attribute :outcome
        validates :worker_key, presence: { message: "must name the worker handed back, got nil" }
        validates :outcome, inclusion: { in: %i[nothing_to_do merged conflicted declined failed],
                                         message: "must be one of nothing_to_do/merged/conflicted/declined/" \
                                                  "failed, got %<value>s" }
      end
    end

    # What became of one worker's committed work when its isolated checkout was
    # handed back. `worker_key` is the same self-describing key
    # {IsolationLease} carries, so the two join on one value; `ref` is nil when
    # nothing was written, absence being the signal exactly as it is on the
    # Outcome itself.
    #
    # A REF, never a path: `refs/lain/worker/<worker>` is repo-relative by
    # construction, so this record can never leak a filesystem path outside the
    # repository, and it deliberately carries no {Isolation::WorkerEnv} -- an
    # env is a live resource handle full of credentials, not attribution.
    #
    # `strategy` names the {Isolation::MergeStrategy} the handback merges with,
    # `fast_forward` whether the parent simply moved to the worker's commit, and
    # `sha` the full SHA that landed -- nil when nothing did, since a record
    # naming a commit on an anchor-only or refused handback would be a lie.
    # These are what a landing queue and a promotion read back.
    #
    # Emitted by {Isolation::Worktree::Handback} itself rather than by a
    # decorator: handback is a one-shot operation whose whole product IS the
    # outcome, so there is no forwarding duck to wrap.
    Handback = Data.define(:worker_key, :outcome, :ref, :strategy, :fast_forward, :sha) do
      include Journalable

      def initialize(worker_key:, outcome:, ref: nil, strategy: nil, fast_forward: false, sha: nil)
        outcome = outcome.to_sym
        Carriers::Handback.check!(worker_key:, outcome:)

        super(worker_key: worker_key.to_s.dup.freeze, outcome:, ref: Freezable::Fields.pinned(ref),
              strategy: Freezable::Fields.pinned(strategy),
              fast_forward: Freezable::Fields.boolean!(fast_forward, "fast_forward"),
              sha: Freezable::Fields.pinned(sha))
      end
    end
  end
end
