# frozen_string_literal: true

module Lain
  # How a worker gets the host-side execution context it runs under, made
  # swappable and bench-scorable: the SAME question -- "give this worker an
  # environment to run in, and let me hand it back when it is done" -- answered
  # by a shared-process baseline ({Null}) or an isolated git checkout
  # ({Worktree}), and later by per-service provisioning that enriches either.
  #
  # The seam is one message: `acquire(worker_id) -> Lease`. A {Lease} carries a
  # {WorkerEnv} (the cwd and env a tool resolves against) and a `#release` that
  # reclaims whatever the acquire provisioned. The two are separated so a
  # strategy can ENRICH the leased WorkerEnv with extra vars (a per-worker
  # DATABASE_URL, say) without reshaping this base -- {Worktree#worker_env_for}
  # is the seam a richer strategy overrides, and the base is untouched.
  #
  # This is the injection point every parallel {Arm} leases per worker; the
  # single-thread control acquires a {Null} lease so it honors the same
  # acquire/release lifecycle a fan-out arm uses without ever needing an
  # isolated checkout.
  module Isolation
  end
end

require_relative "isolation/lease"
require_relative "isolation/null"
require_relative "isolation/worktree"
require_relative "isolation/journal"
