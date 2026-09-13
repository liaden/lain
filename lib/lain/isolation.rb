# frozen_string_literal: true

module Lain
  # How a worker gets the host-side execution context it runs under, made
  # swappable and bench-scorable: one question -- "give this worker an
  # environment, and let me hand it back when it is done" -- answered by a
  # shared-process baseline ({Null}) or an isolated git checkout ({Worktree}).
  #
  # The seam is one message: `acquire(worker_id) -> Lease`. Lease and WorkerEnv
  # are separated so a strategy can ENRICH the leased WorkerEnv with extra vars
  # -- a per-worker DATABASE_URL, say -- by overriding
  # {Worktree#worker_env_for}, leaving this base untouched.
  #
  # The single-thread control acquires a {Null} lease, so it honors the same
  # acquire/release lifecycle a fan-out arm does without ever needing a checkout.
  #
  # Three names sit close enough to confuse: {Lease} is ONE grant of an
  # environment, {LeaseLock} is how two processes avoid granting the same
  # checkout twice, and {Leases} is the run's pool -- who leases from which
  # backend, and the lane and ordinal sequence the workers doing so are named
  # off. A spawn reaches a backend through the pool; an operator-adopted actor
  # is numbered by {Lain::Supervisor} off a sequence the pool cannot see, and
  # {WorkerId} is where the two lanes are proven unable to meet.
  module Isolation
  end
end

require_relative "isolation/worker_id"
require_relative "isolation/lease"
require_relative "isolation/null"
require_relative "isolation/lease_lock"
require_relative "isolation/worktree"
require_relative "isolation/checkout"
require_relative "isolation/working_branch"
require_relative "isolation/merge_strategy"
require_relative "isolation/parent_lock"
require_relative "isolation/worker_handoff"
require_relative "isolation/self_sync"
require_relative "isolation/leases"
require_relative "isolation/landing_queue"
require_relative "isolation/journal"
require_relative "isolation/services"
require_relative "isolation/db_index"
require_relative "isolation/compose"
require_relative "isolation/gc"
