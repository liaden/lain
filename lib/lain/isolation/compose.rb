# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module Isolation
    # Isolation by per-worker `docker compose` stack: DECORATES an inner backend
    # ({Null} or {Worktree}) and, for a project declaring compose services
    # (`.lain/services.rb`), brings up a namespaced stack per worker
    # (`docker compose -p lain_<hash> up -d`), reads back each declared service's
    # published host port, injects the service URLs into the leased {WorkerEnv},
    # and tears the stack down with its volumes (`down -v`) on release.
    #
    # DECORATOR, not a `worker_env_for` override -- {DbIndex}'s reasoning: a
    # per-worker stack owns a RELEASE (`down -v`) that must compose WITH the
    # inner backend's own release, so this wraps a whole inner {Lease}.
    #
    # THE STACK IS PER-WORKER, THE SERVICES ARE PER-STACK. Unlike {DbIndex},
    # which does one createdb per service, the stack is brought up and torn down
    # ONCE per worker however many services are declared; the declarations only
    # each discover their own published port. When none is declared the lease is
    # the inner one and no docker command runs.
    #
    # NEVER `down -v` A STACK WE DID NOT CREATE. `down -v` destroys volumes, so
    # before `up` we probe `docker compose -p <project> ps -q`: a non-empty
    # result means the namespaced project name is already occupied, and since we
    # cannot prove it is ours we REFUSE loudly rather than
    # adopt-and-later-destroy it -- {Worktree} leaving a foreign directory for
    # `git worktree add` to refuse over, one layer up. Having proved the name
    # empty, everything under it after our `up` is ours, so the teardown on a
    # failed or partial `up`, and on release, is always safe.
    #
    # CREDENTIALS STAY IN THE LEASE. The injected URLs live only in the leased
    # WorkerEnv -- sent, not stored -- and never reach a turn's content or a
    # digest. A provisioned service's journalable identity is its
    # {Services::Compose#name} plus the worker key, never its URL.
    class Compose
      # A refusal, surfaced LOUDLY -- the backend never hands back a lease over a
      # stack it could not bring up, and never co-opts a foreign stack. Causes: a
      # docker-compose subcommand exited nonzero, a declared port is not
      # published, or the namespaced project name is already occupied.
      class Refused < Error
        # Carries the OPERATION so a teardown-path (`down`) failure is not
        # mislabeled as an `up`.
        def self.from_compose(operation, project, shell)
          new("docker compose #{operation} for project #{project} failed " \
              "(exit #{shell.exitstatus}): #{shell.stderr.to_s.strip}")
        end
      end

      # One discovered service's injection. `service_name` is the journalable
      # identity, paired with the worker key and NEVER the URL. No per-service
      # release: `down -v` reclaims every service at once.
      Published = Data.define(:service_name, :env_var, :url)

      # The compose-file names `docker compose` itself searches, in its own
      # precedence order; used when no explicit `compose_file:` is injected.
      COMPOSE_FILE_NAMES = %w[compose.yaml compose.yml docker-compose.yaml docker-compose.yml].freeze

      # Scrubbed because a `down -v` targeting the wrong project or file is a
      # destructive misfire. The command-line flags already win over them in
      # compose's precedence, so this removes the ambiguity rather than a bug.
      COMPOSE_CONTEXT_SCRUB = { "COMPOSE_PROJECT_NAME" => nil, "COMPOSE_FILE" => nil }.freeze

      # The env vars that select WHICH docker daemon a command addresses. These
      # are NOT scrubbed -- they carry the user's intended daemon -- but they ARE
      # SNAPSHOTTED per {Stack} at acquire (see {Stack#initialize}). The safety
      # probe (`ps`), `up`, and the release `down -v` can be seconds-to-minutes
      # apart, and each shell reads live ENV at exec; without a snapshot a
      # mid-lease `DOCKER_HOST` change would split the "is this stack ours?" probe
      # from the teardown, so `down -v` could hit a DIFFERENT daemon than the one
      # we proved empty and brought up. Pinning the acquire-time values to every
      # call on the lease keeps up/port/down addressing ONE daemon.
      DOCKER_DAEMON_VARS = %w[DOCKER_HOST DOCKER_CONTEXT].freeze

      # The imperative shell for ONE per-worker stack: the docker-compose CLI
      # bound to a fixed `-p <project> -f <file>`.
      class Stack
        # @param project [String] the `-p` name that scopes every compose
        #   invocation to this worker's own stack
        # @param compose_file [String] the `-f` path every compose invocation
        #   on this Stack targets
        # @param shell_out_factory [#call] builds the subprocess runner each
        #   `docker compose` invocation runs through
        # @param env [#[]] the environment SNAPSHOTTED at acquire for the daemon
        #   vars, defaulting to the live process ENV -- see {DOCKER_DAEMON_VARS}
        #   for why a mid-lease change must not split the probe from the
        #   teardown.
        def initialize(project:, compose_file:, shell_out_factory:, env: ENV)
          @project = project
          @compose_file = compose_file
          @shell_out_factory = shell_out_factory
          @environment = COMPOSE_CONTEXT_SCRUB.merge(
            DOCKER_DAEMON_VARS.to_h { |var| [var, env[var]] }
          ).freeze
        end

        attr_reader :project

        # A non-empty `ps -q` (one container id per line) means occupied -- see
        # the class doc on why that is refused rather than adopted. A NONZERO
        # `ps` (daemon down, TLS error) proves NOTHING and must NOT read as
        # "unoccupied", which would let `up` adopt, and release `down -v`, a
        # pre-existing stack. So it raises the real cause loudly instead.
        def occupied?
          shell = compose("ps", "-q")
          raise Refused.from_compose("ps", @project, shell) unless shell.exitstatus.zero?

          !shell.stdout.to_s.strip.empty?
        end

        def up
          shell = compose("up", "-d")
          raise Refused.from_compose("up", @project, shell) unless shell.exitstatus.zero?
        end

        def down
          shell = compose("down", "-v")
          raise Refused.from_compose("down", @project, shell) unless shell.exitstatus.zero?
        end

        # The default port-discovery {Services::Compose#discover} rides.
        def published_port(service, container_port)
          shell = compose("port", service, container_port.to_s)
          raise Refused.from_compose("port", @project, shell) unless shell.exitstatus.zero?

          parse_port(service, container_port, shell.stdout.to_s)
        end

        private

        # `docker compose port` prints ONE `<host>:<port>` mapping PER LINE
        # (`0.0.0.0:32769`, an IPv6 `[::]:32769`, or a dual-bind pair over two
        # lines). The published host port is the FIRST non-zero one, parsed per
        # line rather than `rpartition` over the whole blob, which would
        # silently take the LAST line and mis-report a differing dual-bind. An
        # unpublished port prints an empty line or `:0`, so no positive port
        # refuses loudly rather than injecting a dead URL.
        def parse_port(service, container_port, output)
          port = output.each_line.filter_map { |line| host_port(line) }.find(&:positive?)
          return port if port

          raise Refused, "compose service #{service.inspect} does not publish container port " \
                         "#{container_port} (docker compose port returned #{output.strip.inspect}); " \
                         "expose it in the compose file"
        end

        # The last colon-segment, so an IPv6 `[::]:32769` yields 32769.
        def host_port(line)
          stripped = line.strip
          stripped.empty? ? nil : stripped.rpartition(":").last.to_i
        end

        def compose(*subcommand)
          shell = @shell_out_factory.call("docker", "compose", "-p", @project, "-f", @compose_file,
                                          *subcommand, environment: @environment)
          shell.run_command
          shell
        end
      end

      # @param services [Enumerable] the declared services; only {Services::Compose}
      #   declarations are acted on, so one `.lain/services.rb` can mix compose
      #   with postgres and each backend picks its own
      # @param inner [#acquire] the backend whose lease this enriches ({Null}/{Worktree})
      # @param paths [Paths] supplies the per-worker `-p` name via {Paths#project_hash}
      # @param project_root [String] where the compose file is resolved from when
      #   `compose_file:` is not given
      # @param compose_file [String, nil] an explicit compose file, else resolved
      #   from `project_root` by {COMPOSE_FILE_NAMES}
      # @param shell_out_factory [#call] builds the subprocess runner, a factory
      #   exactly as {Worktree} and {DbIndex} take one
      # @param env [#[]] the environment the daemon-var snapshot is read from,
      #   defaulting to the live process ENV; injected so a spec pins the
      #   acquire-time daemon deterministically
      def initialize(services:, inner: Null.new, paths: Paths.new, project_root: Dir.pwd,
                     compose_file: nil, shell_out_factory: Mixlib::ShellOut.public_method(:new), env: ENV)
        @services = services
        @inner = inner
        @paths = paths
        @project_root = File.expand_path(project_root)
        @compose_file = compose_file
        @shell_out_factory = shell_out_factory
        @env = env
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
      # its release tears the stack down then releases inner, whose origin it
      # hands back unchanged.
      # @param worker_id [Object] keyed through {Paths#project_hash} into the `-p` name
      # @return [Lease]
      # @raise [Refused] on an occupied project name, a failed `up`, or an
      #   unpublished declared port
      def acquire(worker_id)
        base = @inner.acquire(worker_id)
        compose_services = @services.grep(Services::Compose)
        return base if compose_services.empty?

        stack = stack_for(worker_id)
        guard_unoccupied(stack, base)
        up_and_lease(stack, base, compose_services)
      rescue StandardError
        # The inner lease is ours to reclaim on ANY failure past the acquire, or
        # a Worktree inner strands a checkout. `stack_for` is why this is not
        # redundant with the releases inside guard_unoccupied/up_and_lease: it
        # runs BEFORE both, and {#resolve_compose_file} raises there when the
        # compose file is gone. Double-releasing is harmless -- a {Lease} is
        # idempotent-loud, so the reclaim runs exactly once.
        base&.release
        raise
      end

      private

      def stack_for(worker_id)
        project = "lain_#{@paths.project_hash(worker_id.to_s)}"
        Stack.new(project:, compose_file: resolve_compose_file,
                  shell_out_factory: @shell_out_factory, env: @env)
      end

      # Runs BEFORE any teardown region, so both refusals release ONLY the inner
      # lease already taken -- nothing was brought up, so nothing is torn down.
      # The `rescue` covers the probe-failure raise from {Stack#occupied?} as
      # well as the occupied raise here, so the inner lease is never stranded on
      # either path.
      def guard_unoccupied(stack, base)
        return unless stack.occupied?

        raise Refused, "compose project #{stack.project} already has a running stack; refusing to " \
                       "co-opt or tear down a stack this worker did not create"
      rescue Refused
        base.release
        raise
      end

      # `up` makes the verified-empty project ours, so any failure past here --
      # a nonzero `up`, an unpublished port -- is reaped with `down -v` on OUR
      # project name before the inner lease is reclaimed, and a crashed worker
      # leaks no containers or volumes.
      def up_and_lease(stack, base, compose_services)
        stack.up
        published = compose_services.map { |service| service.discover(stack) }
        Lease.new(worker_env: enrich(base.worker_env, published), origin: base.origin,
                  on_release: -> { release(stack, base) })
      rescue StandardError
        reap(stack)
        base.release
        raise
      end

      def enrich(worker_env, published)
        additions = published.to_h { |one| [one.env_var, one.url] }
        WorkerEnv.new(cwd: worker_env.cwd, env: worker_env.env.merge(additions))
      end

      # Tear the stack down with its volumes, ALWAYS releasing the inner lease --
      # even if `down` raises, the inner checkout must not be stranded.
      def release(stack, base)
        stack.down
      ensure
        base.release
      end

      # Best-effort teardown on the failed-acquire path: a `down` error here
      # would mask the ORIGINAL provisioning failure, the one worth raising.
      def reap(stack)
        stack.down
      rescue StandardError
        nil
      end

      def resolve_compose_file
        return @compose_file if @compose_file

        found = COMPOSE_FILE_NAMES.map { |name| File.join(@project_root, name) }.find { |path| File.exist?(path) }
        found || raise(Refused, "no compose file in #{@project_root} " \
                                "(looked for #{COMPOSE_FILE_NAMES.join(", ")})")
      end
    end
  end
end
