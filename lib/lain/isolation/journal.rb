# frozen_string_literal: true

module Lain
  module Isolation
    # A Journal-duck decorator over any Isolation backend -- {Memory::JournalMemoryRoot}
    # and {Session::Journaled}'s shape, applied to the Isolation seam: `acquire`
    # forwards to the wrapped backend untouched, and each lease transition
    # ADDITIONALLY emits a {Telemetry::IsolationLease} record, so B5's supervisor
    # and any {Arm} can wrap ANY backend -- {Null}, {Worktree}, a future
    # DbIndex/Compose -- without the backend itself ever knowing a journal
    # exists. This is what keeps every backend's own spec journal-ignorant, the
    # same separation {Session} keeps from {Session::Journaled}.
    #
    # Release is journaled only on the release that actually does the work.
    # `acquire` hands back a FRESH {Lease} (cwd/env forwarded from the real one,
    # `on_release` wrapping the real `#release`) rather than the backend's own
    # lease object, so the wrapper's `#release` inherits {Lease}'s own
    # idempotent-loud contract: the underlying reclaim and the journal write
    # both run on the first release, and a double-release journals nothing a
    # second time.
    #
    # `worker_key` on the emitted record is the STRING form of whatever
    # `worker_id` object a caller passed to `acquire` -- the record is a
    # self-describing value regardless of what a caller's worker identity
    # actually is (see {Telemetry::IsolationLease}).
    #
    # A backend `acquire` that RAISES journals nothing -- no phantom
    # `:acquired` for a lease that never existed; the record mirrors what
    # actually happened, load-bearing for lease/thrash accounting. Wrap ONCE,
    # nearest the concrete backend: a supervisor handed an already-wrapped
    # backend must not decorate again, or every transition double-journals.
    class Journal
      # @param backend [#acquire] the real Isolation backend every call
      #   forwards to
      # @param journal [#<<] where {Telemetry::IsolationLease} records land
      def initialize(backend:, journal:)
        @backend = backend
        @journal = journal
      end

      # @param worker_id [Object] the worker leasing an environment
      # @return [Lease] wraps the backend's own lease so its release is
      #   journaled too
      def acquire(worker_id)
        lease = @backend.acquire(worker_id)
        emit(:acquired, worker_id)
        Lease.new(worker_env: lease.worker_env, on_release: -> { release(lease, worker_id) })
      end

      private

      # Runs on the wrapper Lease's first (and only meaningful) release: reclaim
      # via the real lease, then journal -- in that order, so a reclaim failure
      # (a real {Worktree::Refused}) never journals a release that did not
      # happen.
      def release(lease, worker_id)
        released = lease.release
        emit(:released, worker_id) if released
        released
      end

      def emit(kind, worker_id)
        @journal << Telemetry::IsolationLease.new(kind:, worker_key: worker_id.to_s, backend: @backend.class.name)
      end
    end
  end
end
