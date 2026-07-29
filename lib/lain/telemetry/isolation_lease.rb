# frozen_string_literal: true

module Lain
  module Telemetry
    module Guards
      # An isolation-lease record must land on one of the lifecycle kinds and
      # name the worker it belongs to.
      class IsolationLease < Guard
        attribute :kind
        attribute :worker_key
        validates :kind, inclusion: { in: %i[acquired released service_provisioned service_torn_down],
                                      message: "must be one of acquired/released/service_provisioned/" \
                                               "service_torn_down, got %<value>s" }
        validates :worker_key, presence: { message: "must name the worker the lease belongs to, got nil" }
      end
    end

    # One transition in an isolation lease's lifecycle: `kind` names WHICH
    # transition (`:acquired`/`:released` today; `:service_provisioned`/
    # `:service_torn_down` complete the vocabulary for a richer backend --
    # B3's Postgres/Redis DB-index, B4's compose stack -- to emit ALONGSIDE
    # these two, the same "closed enum, not every value reached yet" idiom
    # {Compaction#cache_state} documents for its own unreached `:warm`).
    # `worker_key` is the STRING form of whatever `worker_id` the caller
    # passed to `acquire` -- the same arbitrary-object-as-key idiom
    # {Paths#project_hash} already keys a filesystem path on -- so this record
    # stays a self-describing value regardless of what a caller's worker
    # identity actually is, and is the COUNTABLE key `Compare` sums lease/
    # thrash cost over later (a worker with N acquire/release pairs is
    # visible as N records sharing one `worker_key`). `backend` names the
    # class doing the leasing (a String, not the object), so a report can
    # break lease cost down by strategy.
    #
    # `service` is nil for the base `:acquired`/`:released` pair a lease
    # lifecycle always emits -- there is no service to name yet, only a
    # WorkerEnv -- and is the field a `:service_provisioned`/
    # `:service_torn_down` record from a richer backend would fill with a
    # NAME ("postgres", "redis"), never a connection string: this record
    # must never carry a `DATABASE_URL`/`REDIS_URL` or any credential, only
    # attribution. A backend that wants a URL journaled has to redact it
    # first -- this record gives it nowhere to put the raw bytes.
    #
    # Emitted by {Isolation::Journal}, the Journal-duck decorator
    # ({Memory::JournalMemoryRoot}/{Session::Journaled}'s shape, applied to the
    # Isolation seam) that wraps ANY backend's `acquire`/`release` -- never by a
    # backend ({Null}/{Worktree}/a future DbIndex/Compose) itself, which stays
    # journal-ignorant.
    IsolationLease = Data.define(:kind, :worker_key, :backend, :service) do
      include Journalable

      def initialize(kind:, worker_key:, backend:, service: nil)
        kind = kind.to_sym
        Guards::IsolationLease.check!(kind:, worker_key:)

        super(
          kind:,
          worker_key: worker_key.to_s.dup.freeze,
          backend: backend.to_s.dup.freeze,
          service: service&.to_s&.freeze
        )
      end
    end
  end
end
