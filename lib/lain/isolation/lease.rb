# frozen_string_literal: true

module Lain
  module Isolation
    # A leased execution context and the means to give it back. It carries a
    # {WorkerEnv} (what the worker runs under) and an `on_release` action that
    # reclaims whatever `acquire` provisioned -- a no-op for {Null}, a
    # `git worktree remove` for {Worktree}.
    #
    # A RESOURCE HANDLE, not a value object. Unlike a {Turn} it is deliberately
    # NOT `Ractor.shareable?`: it closes over a mutable release action and tracks
    # whether it has been released, so there is no shareability spec to satisfy
    # here (the same posture {Arm::Run} takes, and for the same reason -- it
    # owns a live resource, not frozen data).
    #
    # Release is IDEMPOTENT-LOUD: safe to call more than once (the reclaim runs
    # exactly once, so a double-release never double-removes a worktree), but
    # observable rather than silent -- the first release returns `true`, every
    # later one returns `false`, and {#released?} reports the state. `#release`
    # marks itself released BEFORE running the action, so an action that raises
    # still leaves the lease settled rather than re-runnable.
    class Lease
      # @param worker_env [WorkerEnv] the cwd/env this lease hands the worker
      # @param on_release [#call] reclaims the provisioned resource; defaults to
      #   a no-op (the {Null} case), so no caller guards on a missing action
      def initialize(worker_env:, on_release: -> {})
        @worker_env = worker_env
        @on_release = on_release
        @released = false
      end

      # @return [WorkerEnv] the leased cwd and env
      attr_reader :worker_env

      # @return [Boolean] whether this lease has already been released
      def released? = @released

      # Reclaim the leased resource, exactly once. A command, not a query -- the
      # seam callers drive is `lease.release` (see {Arm::SingleThread}); it
      # returns a boolean only to make the idempotent-loud contract observable,
      # so PredicateMethod (which reads a boolean return as a predicate name) is
      # a false positive here.
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
