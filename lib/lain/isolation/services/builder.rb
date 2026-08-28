# frozen_string_literal: true

module Lain
  module Isolation
    class Services
      # The evaluation context for `.lain/services.rb`: one registration method
      # per service kind, each appending a frozen declaration and RETURNING it
      # so a later hook can chain off the returned service.
      #
      # instance_eval'd against the user's file with NO sandbox. The keywords a
      # call takes are exactly the value object's, so the DSL and the
      # declaration cannot drift.
      class Builder
        # The DSL verbs, which ARE the stable user surface. Named here so an
        # unknown verb's error can list them.
        #
        # {#redis} is deliberately NOT here while still being a defined method,
        # so `respond_to?(:redis)` answers true for a verb this list omits. The
        # divergence is the point: the method exists only to refuse, and a
        # retired verb belongs in neither the valid set an error reads back nor
        # the {Unknown} path that would strand its author.
        VERBS = %i[postgres compose].freeze

        # The declaration that replaces a retired `redis` line. Spelled out once
        # so the refusal hands over something copy-pasteable AND a spec can
        # declare THIS STRING through the real DSL and check the URL it yields:
        # advice a spec cannot falsify is advice that rots. `scheme:` is load
        # bearing -- {Services::Compose} defaults it to "tcp", and a
        # `tcp://host:port` REDIS_URL fails inside the operator's own app, as
        # far from this refusal as a failure can land.
        REDIS_REPLACEMENT = 'compose service: "redis", container_port: 6379, ' \
                            'env_var: "REDIS_URL", scheme: "redis"'

        # An unrecognized service verb. The DSL is a stable surface, so a typo
        # fails LOUDLY and named rather than as a bare NoMethodError.
        class Unknown < Error; end

        # A verb that WAS real and is not any more. Separate from {Unknown}
        # because a typo and an upgrade are different operator problems: a typo
        # wants the valid set read back, while a file that worked yesterday
        # wants the route that replaced what it declared.
        class Retired < Error; end

        # A second declaration that would silently clobber a first in the lease
        # -- the SAME service kind declared twice, or two DIFFERENT services
        # naming the SAME `env_var`, whose URLs collide when a backend merges
        # them into one WorkerEnv.
        class Duplicate < Error; end

        # `path` and line 1 give backtraces that point into the user's
        # `.lain/services.rb`, not into this evaluator.
        def self.build(source, path)
          builder = new
          builder.instance_eval(source, path, 1)
          builder.to_a
        end

        def initialize
          @declarations = []
        end

        def to_a = @declarations.dup

        def postgres(**) = declare(Services::Postgres.new(**))
        def compose(**) = declare(Services::Compose.new(**))

        # Retired rather than merely dropped, because a working `.lain/services.rb`
        # hits this on upgrade and a bare "unknown service" would strand it.
        #
        # Every other service here derives its resource from the WORKER KEY --
        # postgres names a database from it, compose names a project from it.
        # Redis alone allocated a logical DB-index out of state shared across one
        # backend's workers, so a second backend resolved in one run handed out a
        # colliding index, and redis's own 16 logical DBs capped the fan-out on
        # top of that. A container has neither problem, so that is the route.
        def redis(**)
          raise Retired, "the `redis` service was retired from .lain/services.rb; a container is the " \
                         "isolation route for redis now -- put it in your compose file and declare it " \
                         "here as `#{REDIS_REPLACEMENT}`, which leases a stack per worker with no " \
                         "shared DB-index and no 16-database ceiling. " \
                         "Known services: #{VERBS.join(", ")}"
        end

        def method_missing(name, *, **)
          raise Unknown, "unknown service #{name.inspect} in .lain/services.rb; " \
                         "known services: #{VERBS.join(", ")}"
        end

        def respond_to_missing?(name, include_private = false) = VERBS.include?(name) || super

        private

        def declare(service)
          refuse_duplicate_name(service)
          refuse_duplicate_env_var(service)
          @declarations << service
          service
        end

        def refuse_duplicate_name(service)
          return unless @declarations.any? { |existing| existing.name == service.name }

          raise Duplicate, "duplicate #{service.name} service in .lain/services.rb; " \
                           "declare each service at most once"
        end

        # Two declarations sharing an `env_var` -- even across DIFFERENT service
        # kinds, whose names differ -- would silently clobber in the merge, so
        # the second refuses loudly and names both culprits.
        def refuse_duplicate_env_var(service)
          return unless service.respond_to?(:env_var)

          clash = @declarations.find do |existing|
            existing.respond_to?(:env_var) && existing.env_var == service.env_var
          end
          return unless clash

          raise Duplicate, "duplicate env var #{service.env_var.inspect} in .lain/services.rb " \
                           "(declared by both #{clash.name} and #{service.name}); a second " \
                           "declaration would silently clobber the first's injected URL"
        end
      end
    end
  end
end
