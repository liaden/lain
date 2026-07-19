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
    # DECORATOR, not a `worker_env_for` override -- same reasoning as {DbIndex}:
    # a per-worker stack owns a RELEASE (`down -v`) that must compose WITH the
    # inner backend's own release, so this wraps a whole inner {Lease} and layers
    # over EITHER inner backend unchanged.
    #
    # THE STACK IS PER-WORKER, THE SERVICES ARE PER-STACK. Unlike {DbIndex} (one
    # createdb per service), the stack is brought up and torn down ONCE per
    # worker regardless of how many services are declared; the declarations only
    # each discover their own published port (the dogfooded port-discovery seam,
    # {Services::Compose#discover}). When no compose service is declared the lease
    # is the inner one and no docker command runs -- Null-by-empty-enumeration,
    # exactly as {DbIndex} degrades.
    #
    # NEVER `down -v` A STACK WE DID NOT CREATE. `down -v` destroys volumes, so
    # before `up` we probe `docker compose -p <project> ps -q`: a non-empty
    # result means the namespaced project name is already occupied, and since we
    # cannot prove it is ours we REFUSE loudly rather than adopt-and-later-destroy
    # it (mirroring {Worktree} leaving a foreign directory for `git worktree add`
    # to refuse over). Having proved the name empty, everything under it after our
    # `up` is ours -- so the teardown on a failed/partial `up`, and on release, is
    # always safe. The `lain_<project_hash>` namespacing makes a real collision
    # with a user's own stack vanishingly unlikely; the probe is the belt.
    #
    # CREDENTIALS STAY IN THE LEASE. The injected URLs live only in the leased
    # WorkerEnv (sent-not-stored, like {Workspace}); they never reach a turn's
    # content or a digest. A provisioned service's journalable identity is its
    # {Services::Compose#name} plus the worker key, never its URL.
    class Compose
      # A refusal, surfaced LOUDLY -- the backend never hands back a lease over a
      # stack it could not bring up, and never co-opts a foreign stack. Causes: a
      # docker-compose subcommand exited nonzero, a declared port is not
      # published, or the namespaced project name is already occupied. Named per
      # the error-taxonomy convention (mirrors {Worktree::Refused}).
      class Refused < Error
        # Carries the OPERATION so a teardown-path (`down`) failure is not
        # mislabeled as an `up`.
        def self.from_compose(operation, project, shell)
          new("docker compose #{operation} for project #{project} failed " \
              "(exit #{shell.exitstatus}): #{shell.stderr.to_s.strip}")
        end
      end

      # One discovered service's injection: the env var it names and the URL that
      # var takes. `service_name` is the journalable identity (B6) -- paired with
      # the worker key, NEVER the URL. No per-service release: the stack teardown
      # (`down -v`) reclaims every service at once, so this carries no `release`.
      Published = Data.define(:service_name, :env_var, :url)

      # The compose-file names `docker compose` itself searches, in its own
      # precedence order; used when no explicit `compose_file:` is injected.
      COMPOSE_FILE_NAMES = %w[compose.yaml compose.yml docker-compose.yaml docker-compose.yml].freeze

      # The compose-context env vars that would redirect our EXPLICIT `-p`/`-f`.
      # `COMPOSE_PROJECT_NAME` and `COMPOSE_FILE` are scrubbed because a
      # `down -v` targeting the wrong project or file is a destructive misfire;
      # the command-line flags already win over them in compose's precedence, so
      # this scrub is defense-in-depth that removes the ambiguity entirely.
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
      # bound to a fixed `-p <project> -f <file>`. This is the port-discovery
      # context {Services::Compose#discover} invokes, and the lifecycle the
      # backend drives (`up`/`ps`/`down`).
      class Stack
        # @param env [#[]] the environment SNAPSHOTTED at acquire for the daemon
        #   vars (defaults to the live process ENV); every call on this Stack
        #   then addresses the acquire-time daemon, so a mid-lease change can't
        #   split the probe from the teardown (see {DOCKER_DAEMON_VARS}).
        def initialize(project:, compose_file:, shell_out_factory:, env: ENV)
          @project = project
          @compose_file = compose_file
          @shell_out_factory = shell_out_factory
          @environment = COMPOSE_CONTEXT_SCRUB.merge(
            DOCKER_DAEMON_VARS.to_h { |var| [var, env[var]] }
          ).freeze
        end

        attr_reader :project

        # Is a stack already running under this project name? A non-empty
        # `ps -q` (one container id per line) means occupied -- see the class doc
        # on why an occupied name is refused rather than adopted. A NONZERO `ps`
        # (daemon down, TLS error) proves NOTHING -- it must NOT read as
        # "unoccupied" and let `up` adopt (then, on release, `down -v`) a
        # pre-existing stack -- so it raises the real cause loudly instead.
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

        # The host port compose published `service`'s `container_port` on. This
        # is the default port-discovery {Services::Compose#discover} rides.
        def published_port(service, container_port)
          shell = compose("port", service, container_port.to_s)
          raise Refused.from_compose("port", @project, shell) unless shell.exitstatus.zero?

          parse_port(service, container_port, shell.stdout.to_s)
        end

        private

        # `docker compose port` prints ONE `<host>:<port>` mapping PER LINE
        # (`0.0.0.0:32769`, an IPv6 `[::]:32769`, or a dual-bind pair over two
        # lines). The published host port is the FIRST non-zero one -- parsing
        # per line, not `rpartition` over the whole blob, which would silently
        # take the LAST line and mis-report a differing dual-bind. An unpublished
        # port prints an empty line or `:0`, so no positive port -> refused
        # loudly rather than injecting a dead URL.
        def parse_port(service, container_port, output)
          port = output.each_line.filter_map { |line| host_port(line) }.find(&:positive?)
          return port if port

          raise Refused, "compose service #{service.inspect} does not publish container port " \
                         "#{container_port} (docker compose port returned #{output.strip.inspect}); " \
                         "expose it in the compose file"
        end

        # The port from one `<host>:<port>` line -- the last colon-segment, so
        # `[::]:32769` yields 32769. A blank line contributes nothing.
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
      #   with pg/redis and each backend picks its own
      # @param inner [#acquire] the backend whose lease this enriches ({Null}/{Worktree})
      # @param paths [Paths] supplies the per-worker `-p` name via {Paths#project_hash}
      # @param project_root [String] where the compose file is resolved from when
      #   `compose_file:` is not given
      # @param compose_file [String, nil] an explicit compose file, else resolved
      #   from `project_root` by {COMPOSE_FILE_NAMES}
      # @param shell_out_factory [#call] builds the subprocess runner, injected as
      #   a factory exactly as {Worktree} and {DbIndex} do
      # @param env [#[]] the environment the daemon-var snapshot is read from
      #   (defaults to the live process ENV); injected so a spec pins the
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

      # Lease the inner backend, and -- for a project declaring compose services
      # -- bring up a namespaced stack, discover each service's published port,
      # and hand back a lease whose WorkerEnv carries the inner cwd plus the
      # service URLs and whose release tears the stack down then releases inner.
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
      end

      private

      def stack_for(worker_id)
        project = "lain_#{@paths.project_hash(worker_id.to_s)}"
        Stack.new(project:, compose_file: resolve_compose_file,
                  shell_out_factory: @shell_out_factory, env: @env)
      end

      # Runs BEFORE any teardown region. A stack already running under our
      # namespaced name is not ours to bring up or (later) `down -v`; a `ps`
      # probe that could not run (nonzero exit -- daemon down, TLS error) proves
      # nothing and must not be read as "unoccupied". Both refuse loudly, and
      # both release ONLY the inner lease we already took -- nothing was brought
      # up, so nothing is torn down. The `rescue` covers the probe-failure raise
      # from {Stack#occupied?} as well as our own occupied raise, so the inner
      # lease is never stranded on either path.
      def guard_unoccupied(stack, base)
        return unless stack.occupied?

        raise Refused, "compose project #{stack.project} already has a running stack; refusing to " \
                       "co-opt or tear down a stack this worker did not create"
      rescue Refused
        base.release
        raise
      end

      # `up` makes the (verified-empty) project ours, so any failure past here --
      # a nonzero `up`, an unpublished port -- is reaped with `down -v` on OUR
      # project name before the inner lease is reclaimed; a crashed worker leaks
      # no containers or volumes.
      def up_and_lease(stack, base, compose_services)
        stack.up
        published = compose_services.map { |service| service.discover(stack) }
        Lease.new(worker_env: enrich(base.worker_env, published),
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

      # Best-effort teardown on the failed-acquire path: a `down` error here would
      # mask the ORIGINAL provisioning failure (the one worth raising), so it is
      # swallowed -- exactly {DbIndex#roll_back}'s posture.
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
