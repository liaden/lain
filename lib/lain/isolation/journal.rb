# frozen_string_literal: true

module Lain
  module Isolation
    # A Journal-duck decorator over any Isolation backend, {Session::Journaled}'s
    # shape applied to this seam: `acquire` forwards untouched and each lease
    # transition ADDITIONALLY emits a {Telemetry::IsolationLease} record, so a
    # supervisor or an {Arm} can wrap ANY backend without the backend knowing a
    # journal exists -- which is what keeps every backend's own spec
    # journal-ignorant.
    #
    # `acquire` hands back a FRESH {Lease} rather than the backend's own, so the
    # wrapper's `#release` inherits {Lease}'s idempotent-loud contract: the
    # underlying reclaim and the journal write both run on the first release,
    # and a double-release journals nothing a second time.
    #
    # A backend `acquire` that RAISES journals nothing -- no phantom `:acquired`
    # for a lease that never existed, which is load-bearing for lease and thrash
    # accounting. Wrap ONCE, nearest the concrete backend: a supervisor handed
    # an already-wrapped backend must not decorate again, or every transition
    # double-journals.
    class Journal
      # @param backend [#acquire] the real Isolation backend every call
      #   forwards to
      # @param journal [#<<] where {Telemetry::IsolationLease} records land
      def initialize(backend:, journal:)
        @backend = backend
        @journal = journal
      end

      # Forwarded, because a handback reads its target off the fleet's
      # isolation and this decorator stands between that caller and the
      # backend that knows it.
      # @return [#name, #tip, #current_in?] the wrapped backend's working branch
      def base = @backend.base

      # @param worker_id [Object] the worker leasing an environment
      # @return [Lease] wraps the backend's own lease so its release is
      #   journaled too
      def acquire(worker_id)
        lease = @backend.acquire(worker_id)
        emit(:acquired, worker_id, lease.origin)
        Lease.new(worker_env: lease.worker_env, origin: lease.origin, on_release: -> { release(lease, worker_id) })
      end

      private

      # Reclaim via the real lease, THEN journal, so a reclaim failure (a real
      # {Worktree::Refused}) never journals a release that did not happen.
      def release(lease, worker_id)
        released = lease.release
        emit(:released, worker_id, lease.origin) if released
        released
      end

      def emit(kind, worker_id, origin)
        @journal << Telemetry::IsolationLease.new(kind:, worker_key: worker_id.to_s, backend: @backend.class.name,
                                                  **origin.to_h)
      end
    end
  end
end
