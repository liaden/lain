# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # An isolation-lease record must land on one of the lifecycle kinds and
      # name the worker it belongs to.
      class IsolationLease < Declarative::Carrier
        attribute :kind
        attribute :worker_key
        validates :kind, inclusion: { in: %i[acquired released service_provisioned service_torn_down],
                                      message: "must be one of acquired/released/service_provisioned/" \
                                               "service_torn_down, got %<value>s" }
        validates :worker_key, presence: { message: "must name the worker the lease belongs to, got nil" }
      end
    end

    # One transition in an isolation lease's lifecycle. The two service kinds
    # complete the vocabulary for a richer backend -- a per-worker Postgres
    # database, a compose stack -- to emit alongside acquire/release: a closed enum whose
    # every value is not yet reached, the idiom {Compaction#cache_state} keeps
    # for its own `:warm`.
    #
    # `worker_key` is the STRING form of whatever `worker_id` the caller passed
    # to `acquire`, so the record stays self-describing whatever a caller's
    # worker identity is, and is the COUNTABLE key `Compare` sums lease and
    # thrash cost over. `backend` names the leasing class as a String, so a
    # report can break that cost down by strategy.
    #
    # `service` must carry a NAME ("postgres", "compose_cache") and NEVER a
    # connection string: this record may not hold a `DATABASE_URL` or any
    # credential, only attribution, and it gives a backend nowhere to put the
    # raw bytes.
    #
    # Emitted by {Isolation::Journal}, never by a backend itself, which stays
    # journal-ignorant.
    IsolationLease = Data.define(:kind, :worker_key, :backend, :service) do
      include Journalable

      def initialize(kind:, worker_key:, backend:, service: nil)
        kind = kind.to_sym
        Carriers::IsolationLease.check!(kind:, worker_key:)

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
