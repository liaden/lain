# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module Isolation
    # Isolation by per-worker database: DECORATES an inner backend ({Null} or
    # {Worktree}) and, for each service a project declares in `.lain/services.rb`,
    # provisions a per-worker Postgres DB (`createdb lain_worker_<hash>`),
    # injecting DATABASE_URL into the leased {WorkerEnv} and reclaiming it
    # (dropdb) on release.
    #
    # EVERY RESOURCE IS NAMED FROM THE WORKER KEY, never allocated out of a
    # counter shared across workers. That is what lets two backends resolved in
    # one run stay disjoint without coordinating, and it is why a service whose
    # isolation needs an allocator belongs in {Isolation::Compose} instead.
    #
    # The NAME is older than the class: it once also handed out logical Redis
    # DB-indices out of such an allocator, which is the shared state the rule
    # above was written against. Only the worker-keyed half remains.
    #
    # SO DOES THE PLURAL. {Services::Postgres} is currently the ONLY class
    # answering `#provision` -- {Services::Compose} answers `#discover`, and
    # {CLI::IsolationBackend#with_databases} selects on `respond_to?(:provision)`
    # -- and {Builder#refuse_duplicate_name} refuses a second postgres, whose
    # `#name` is the constant `:postgres` whatever its prefix. So every
    # reachable configuration hands this zero or one service, and neither
    # `provision_all`'s rollback accumulator nor `release`'s
    # attempt-every-teardown loop can reach n > 1 from production today. Both
    # stay: the shape is right, the next thing to answer `#provision` restores
    # the reach, and a loop that degrades to one iteration costs nothing.
    #
    # DECORATOR, not a `worker_env_for` override. The base's enrichment seam only
    # names extra env vars; a per-worker DB also owns a RELEASE (dropdb) that
    # must compose WITH the inner backend's own release, so this wraps a whole
    # inner {Lease} rather than subclassing {Worktree}.
    #
    # Provisioning is the IMPERATIVE SHELL. The declarations are frozen, pure
    # value objects; the side effects run here, at lease time. When a project
    # declares no services the loop over an empty collection provisions nothing
    # -- Null-Object by an empty enumeration, not a nil check.
    #
    # CREDENTIALS STAY IN THE LEASE. The injected URLs live only in the leased
    # WorkerEnv -- sent, not stored -- and never reach a turn's content or a
    # digest. The journalable identity of a provisioned service is
    # {Provisioned#service_name} plus the worker key, never its URL.
    class DbIndex
      # A refusal, surfaced LOUDLY -- the strategy never hands back a lease that
      # silently shares a database. Raised on a `createdb` collision with a
      # pre-existing database, and on a `dropdb` that fails for a real reason.
      class Refused < Error; end

      # One provisioned service's outcome. `service_name` is the journalable
      # identity, paired with the worker key and NEVER the URL.
      Provisioned = Data.define(:service_name, :env_var, :url, :release)

      # The lease-time imperative capabilities a service provisions against: the
      # shell the frozen declarations orchestrate but never embody.
      class Provisioner
        def initialize(worker_key:, shell_out_factory:)
          @worker_key = worker_key
          @shell_out_factory = shell_out_factory
        end

        attr_reader :worker_key

        def run(*argv)
          shell = @shell_out_factory.call(*argv)
          shell.run_command
          shell
        end
      end

      # @param services [Enumerable<#provision>] the declared services ({Services})
      # @param inner [#acquire] the backend whose lease this enriches ({Null}/{Worktree})
      # @param paths [Paths] supplies the per-worker DB-name key via {Paths#project_hash}
      # @param shell_out_factory [#call] builds the subprocess runner, a factory
      #   exactly as {Worktree} takes one, so a spec substitutes it
      def initialize(services:, inner: Null.new, paths: Paths.new,
                     shell_out_factory: Mixlib::ShellOut.public_method(:new))
        @services = services
        @inner = inner
        @paths = paths
        @shell_out_factory = shell_out_factory
      end

      # Forwarded: a handback reads its target off the fleet's isolation, and
      # this decorator stands in front of the backend that knows it.
      # @return [#name, #tip, #current_in?] the inner backend's working branch
      def base = @inner.base

      # Forwarded: whether release kept a dirty checkout is the inner
      # backend's to answer.
      # @param path [String] a lease's checkout, as its origin names it
      # @return [Boolean]
      def retained?(path) = @inner.retained?(path)

      # Forwarded: the repository a lease was cut from is the inner backend's
      # to answer.
      # @return [String] the inner backend's repository
      def repo_root = @inner.repo_root

      # The lease's WorkerEnv carries the inner cwd plus the service URLs, and
      # its release reclaims the services then the inner lease, whose origin
      # it hands back unchanged.
      # @param worker_id [Object] keyed through {Paths#project_hash} into the DB-name hash
      # @return [Lease]
      # @raise [Refused] on a createdb collision
      def acquire(worker_id)
        base = @inner.acquire(worker_id)
        provisioned = provision_all(@paths.project_hash(worker_id.to_s))
        Lease.new(worker_env: enrich(base.worker_env, provisioned), origin: base.origin,
                  on_release: ->(discard: false) { release(provisioned, base, discard:) })
      rescue StandardError
        # provision_all rolls back the SERVICES it provisioned; the inner lease
        # is ours to reclaim here, or a Worktree inner leaks a checkout on every
        # failed acquire.
        base&.release
        raise
      end

      private

      # On ANY failure, roll back the accumulator so far, so a failed acquire
      # leaks no database.
      def provision_all(worker_key)
        context = Provisioner.new(worker_key:, shell_out_factory: @shell_out_factory)
        @services.each_with_object([]) do |service, provisioned|
          provisioned << service.provision(context)
        rescue StandardError
          roll_back(provisioned)
          raise
        end
      end

      # Secondary release errors are swallowed on purpose: the ORIGINAL
      # provisioning failure is the one worth raising.
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

      # Reclaim every service INDEPENDENTLY: a raising teardown (a failing
      # dropdb) must not abort the loop and strand its siblings, whose databases
      # would then outlive the run. Every teardown is attempted and the first
      # failure is re-raised afterward; the inner lease is ALWAYS released in the
      # ensure, even on that re-raise.
      def release(provisioned, base, discard: false)
        failures = provisioned.filter_map { |one| release_error(one) }
        raise failures.first unless failures.empty?
      ensure
        base.release(discard:)
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
