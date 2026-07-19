# frozen_string_literal: true

require "monitor"
require "mixlib/shellout"

module Lain
  module Isolation
    # Isolation by per-worker database: DECORATES an inner backend ({Null} or
    # {Worktree}) and, for each service a project declares in `.lain/services.rb`,
    # provisions a per-worker Postgres DB (`createdb lain_worker_<hash>`) and a
    # distinct Redis DB-index, injecting DATABASE_URL/REDIS_URL into the leased
    # {WorkerEnv} and reclaiming both (dropdb / index-release) on release.
    #
    # DECORATOR, not a `worker_env_for` override. The base's enrichment seam only
    # names extra env vars; a per-worker DB also owns a RELEASE (dropdb, index
    # return) that must compose WITH the inner backend's own release, so this
    # wraps a whole inner {Lease} rather than subclassing {Worktree}. It layers
    # over EITHER inner backend unchanged.
    #
    # Provisioning is the IMPERATIVE SHELL. The declarations ({Services::Postgres},
    # {Services::Redis}) are frozen, pure value objects; the side effects
    # (createdb, index allocation) all run here, at lease time. When a project
    # declares no services the loop over an empty collection provisions nothing
    # and the lease is the inner one, enriched with no vars -- a code-only lease
    # by an empty enumeration, not a nil check.
    #
    # CREDENTIALS STAY IN THE LEASE. The injected URLs live only in the leased
    # WorkerEnv (sent-not-stored, like {Workspace}); they never reach a turn's
    # content or a digest. The journalable identity of a provisioned service is
    # {Provisioned#service_name} plus the worker key, never its URL.
    class DbIndex
      # A refusal, surfaced LOUDLY -- the strategy never hands back a lease that
      # silently shares a database or wraps onto a used Redis index. Two causes: a
      # `createdb` collision with a pre-existing database, or Redis DB-index pool
      # exhaustion. Named per the error-taxonomy convention, next to the backend
      # that raises it (mirrors {Worktree::Refused}).
      class Refused < Error; end

      # One provisioned service's outcome: the env var it injects, the URL that
      # var takes, and the release that reclaims it. `service_name` is the
      # journalable identity (B6) -- paired with the worker key, NEVER the URL.
      Provisioned = Data.define(:service_name, :env_var, :url, :release)

      # The lease-time imperative capabilities a service provisions against: run a
      # command, and claim/release a Redis DB-index from the shared pool. This is
      # the imperative shell the frozen declarations orchestrate but never embody.
      class Provisioner
        def initialize(worker_key:, shell_out_factory:, pool:)
          @worker_key = worker_key
          @shell_out_factory = shell_out_factory
          @pool = pool
        end

        attr_reader :worker_key

        def run(*argv)
          shell = @shell_out_factory.call(*argv)
          shell.run_command
          shell
        end

        def claim_index(max) = @pool.claim(max)
        def release_index(index) = @pool.release(index)
      end

      # The Redis DB-index allocator, shared across every worker one backend
      # leases. Indices run 1..(max-1) -- index 0 is the reserved default a worker
      # draws OFF of. Serialized so concurrent acquires never hand two workers one
      # index, and loud on exhaustion (the card's escalation: never wrap onto a
      # used index).
      class Pool
        def initialize
          @claimed = Set.new
          @monitor = Monitor.new
        end

        def claim(max)
          @monitor.synchronize do
            index = (1...max).find { |candidate| !@claimed.include?(candidate) }
            unless index
              raise Refused, "Redis DB-index pool exhausted: all #{max - 1} indices (1..#{max - 1}) " \
                             "off the default 0 are in use -- refusing to wrap onto a used index"
            end

            @claimed.add(index)
            index
          end
        end

        def release(index) = @monitor.synchronize { @claimed.delete(index) }
      end

      # @param services [Enumerable<#provision>] the declared services ({Services})
      # @param inner [#acquire] the backend whose lease this enriches ({Null}/{Worktree})
      # @param paths [Paths] supplies the per-worker DB-name key via {Paths#project_hash}
      # @param shell_out_factory [#call] builds the subprocess runner, injected as
      #   a factory exactly as {Worktree} and {Tools::Bash} do, so a spec substitutes it
      def initialize(services:, inner: Null.new, paths: Paths.new,
                     shell_out_factory: Mixlib::ShellOut.public_method(:new))
        @services = services
        @inner = inner
        @paths = paths
        @shell_out_factory = shell_out_factory
        @pool = Pool.new
      end

      # Lease the inner backend, provision every declared service for this worker,
      # and hand back a lease whose WorkerEnv carries the inner cwd plus the
      # service URLs, and whose release reclaims the services then the inner lease.
      # @param worker_id [Object] keyed through {Paths#project_hash} into the DB-name hash
      # @return [Lease]
      # @raise [Refused] on a createdb collision or Redis pool exhaustion
      def acquire(worker_id)
        base = @inner.acquire(worker_id)
        provisioned = provision_all(@paths.project_hash(worker_id.to_s))
        Lease.new(worker_env: enrich(base.worker_env, provisioned),
                  on_release: -> { release(provisioned, base) })
      rescue StandardError
        # provision_all rolls back the SERVICES it provisioned; the inner lease
        # it already acquired is ours to reclaim here, or a Worktree inner leaks a
        # checkout on every failed acquire.
        base&.release
        raise
      end

      private

      # Provision each service in order; on ANY failure, roll back what already
      # provisioned (the accumulator so far) so a failed acquire leaks no
      # database or held index.
      def provision_all(worker_key)
        context = Provisioner.new(worker_key:, shell_out_factory: @shell_out_factory, pool: @pool)
        @services.each_with_object([]) do |service, provisioned|
          provisioned << service.provision(context)
        rescue StandardError
          roll_back(provisioned)
          raise
        end
      end

      # Undo a partial acquire. Secondary release errors are swallowed on purpose
      # -- the ORIGINAL provisioning failure is the one worth raising, and a best-
      # effort cleanup must not mask it.
      def roll_back(provisioned)
        provisioned.each do |one|
          one.release.call
        rescue StandardError
          nil
        end
      end

      def enrich(worker_env, provisioned)
        additions = provisioned.to_h { |one| [one.env_var, one.url] }
        WorkerEnv.new(cwd: worker_env.cwd, env: worker_env.env.merge(additions))
      end

      # Reclaim every service INDEPENDENTLY -- a raising teardown (a failing
      # dropdb) must not abort the loop and strand its siblings (a held Redis
      # index would leak for the process lifetime). Every teardown is attempted,
      # failures are aggregated, and the first is re-raised loudly afterward; the
      # inner lease is ALWAYS released in the ensure, even on that re-raise.
      def release(provisioned, base)
        failures = provisioned.filter_map { |one| release_error(one) }
        raise failures.first unless failures.empty?
      ensure
        base.release
      end

      # Run one teardown, returning its error (never raising) so the caller can
      # attempt every sibling before surfacing a failure.
      def release_error(one)
        one.release.call
        nil
      rescue StandardError => e
        e
      end
    end
  end
end
