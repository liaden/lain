# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A handback record must name the worker whose work it disposed of and
      # land on one of the outcomes the operation can reach. The kinds are
      # {Isolation::Worktree::Handback::Outcome::KINDS}, and the sync outcomes
      # {Isolation::SelfSync::Result::OUTCOMES}, held verbatim here rather than
      # referenced, so telemetry depends on the isolation tier for nothing (the
      # same reason {SeamDecision} holds {Plan::SIZES} verbatim).
      class Handback < Declarative::Carrier
        attribute :worker_key
        attribute :outcome
        attribute :sync
        validates :worker_key, presence: { message: "must name the worker handed back, got nil" }
        validates :outcome, inclusion: { in: %i[nothing_to_do merged conflicted declined failed],
                                         message: "must be one of nothing_to_do/merged/conflicted/declined/" \
                                                  "failed, got %<value>s" }
        validates :sync, inclusion: { in: %i[current synced conflicted lost dirty disabled failed], allow_nil: true,
                                      message: "must be one of current/synced/conflicted/lost/dirty/disabled/" \
                                               "failed, got %<value>s" }
      end
    end

    # What became of one worker's committed work when its isolated checkout was
    # handed back. `worker_key` is the same self-describing key
    # {IsolationLease} carries, so the two join on one value; `ref` is nil when
    # nothing was written, absence being the signal exactly as it is on the
    # Outcome itself.
    #
    # It deliberately carries no {Isolation::WorkerEnv} -- an env is a live
    # resource handle full of credentials, not attribution.
    #
    # `strategy` names the {Isolation::MergeStrategy} the handback merges with,
    # `fast_forward` whether the parent simply moved to the worker's commit, and
    # `sha` the full SHA that landed -- nil when nothing did, since a record
    # naming a commit on an anchor-only or refused handback would be a lie.
    # These are what a landing queue and a promotion read back.
    #
    # The rest is what the {Isolation::SelfSync} did to the worker's checkout
    # just before, so the one record a reader opens says whether a rebase ran:
    # `sync` is its outcome (nil when none ran), `attempts` one entry per
    # rebase with whose attempt it measured, how many files conflicted, and how
    # it ended, `dirty` and `path` a checkout left with uncommitted work -- the
    # same checkout path {IsolationLease} already records -- and `detail` why
    # it ended as it did.
    #
    # Emitted by {Isolation::Worktree::Handback} itself rather than by a
    # decorator: handback is a one-shot operation whose whole product IS the
    # outcome, so there is no forwarding duck to wrap.
    Handback = Data.define(:worker_key, :outcome, :ref, :strategy, :fast_forward, :sha,
                           :sync, :attempts, :dirty, :path, :detail) do
      include Journalable

      def initialize(worker_key:, outcome:, ref: nil, strategy: nil, fast_forward: false, sha: nil,
                     sync: nil, attempts: [], dirty: false, path: nil, detail: "")
        outcome = outcome.to_sym
        sync = sync&.to_sym
        Carriers::Handback.check!(worker_key:, outcome:, sync:)

        super(worker_key: worker_key.to_s.dup.freeze, outcome:, ref: Freezable::Fields.pinned(ref),
              strategy: Freezable::Fields.pinned(strategy),
              fast_forward: Freezable::Fields.boolean!(fast_forward, "fast_forward"),
              sha: Freezable::Fields.pinned(sha), sync:, attempts: Ractor.make_shareable(attempts.map(&:dup)),
              dirty: Freezable::Fields.boolean!(dirty, "dirty"), path: Freezable::Fields.pinned(path),
              detail: -detail.to_s)
      end
    end
  end
end
