# frozen_string_literal: true

module Lain
  module Isolation
    # A leased execution context and the means to give it back. It carries a
    # {WorkerEnv} (what the worker runs under) and an `on_release` action that
    # reclaims whatever `acquire` provisioned -- a no-op for {Null}, a
    # `git worktree remove` for {Worktree}.
    #
    # A RESOURCE HANDLE, not a value object, and deliberately NOT
    # `Ractor.shareable?`: it closes over a mutable release action and tracks
    # whether it has been released, so there is no shareability spec to satisfy
    # here -- {Arm::Run}'s posture, for its reason.
    #
    # Release is IDEMPOTENT-LOUD: safe to call more than once (the reclaim runs
    # exactly once, so a double-release never double-removes a worktree), but
    # observable rather than silent -- the first release returns `true`, every
    # later one returns `false`, and {#released?} reports the state. `#release`
    # marks itself released BEFORE running the action, so an action that raises
    # still leaves the lease settled rather than re-runnable.
    class Lease
      # Where a lease's checkout is, the commit it was cut from, and the branch
      # that commit was read from -- what a reaper needs to judge a checkout
      # after the process that leased it is gone. Every field is nil for a
      # backend that cuts no checkout.
      Origin = Data.define(:path, :base, :branch) do
        def initialize(path: nil, base: nil, branch: nil)
          super(path: Freezable::Fields.pinned(path), base: Freezable::Fields.pinned(base),
                branch: Freezable::Fields.pinned(branch))
        end
      end

      # @param worker_env [WorkerEnv] the cwd/env this lease hands the worker
      # @param on_release [#call] reclaims the provisioned resource; defaults to
      #   a no-op (the {Null} case), so no caller guards on a missing action
      # @param origin [Origin] where the leased checkout came from
      def initialize(worker_env:, on_release: -> {}, origin: Origin.new)
        # The environment names the checkout, from the one object that knows
        # it: every decorator keeps the origin, and some rebuild the env.
        @worker_env = worker_env.with(checkout: origin.path)
        @on_release = on_release
        @origin = origin
        @released = false
      end

      # @return [WorkerEnv] the leased cwd and env, naming the checkout
      #   {#origin} names
      attr_reader :worker_env

      # @return [Origin] where the leased checkout came from
      attr_reader :origin

      # @return [Boolean] whether this lease has already been released
      def released? = @released

      # Reclaim the leased resource, exactly once. A command, not a query: it
      # returns a boolean only to make the idempotent-loud contract observable,
      # so PredicateMethod -- which reads a boolean return as a predicate name
      # -- is a false positive here.
      # @return [Boolean] true on the release that did the work, false on a
      #   later (already-released) call
      def release # rubocop:disable Naming/PredicateMethod
        return false if @released

        @released = true
        @on_release.call
        true
      end
    end
  end
end
