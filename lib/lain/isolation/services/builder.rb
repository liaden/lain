# frozen_string_literal: true

module Lain
  module Isolation
    class Services
      # The evaluation context for `.lain/services.rb`. The DSL surface itself:
      # one registration method per service kind, in the middleware-registration
      # idiom ({Middleware::Stack#use}) -- each appends a frozen declaration and
      # RETURNS it, so a later hook can chain off the returned service.
      #
      # instance_eval'd against the user's file with NO sandbox (Rails-like): the
      # keywords a call takes are exactly the value object's, so the DSL and the
      # declaration cannot drift.
      class Builder
        # The DSL verbs, which ARE the stable user surface. Named here so an
        # unknown verb's error can list them.
        VERBS = %i[postgres redis compose].freeze

        # An unrecognized service verb in `.lain/services.rb`. The DSL is a stable
        # surface, so a typo fails LOUDLY and named rather than as a bare
        # NoMethodError. Named per the error-taxonomy convention, next to the
        # evaluator that raises it.
        class Unknown < Error; end

        # A second declaration that would silently clobber a first in the lease --
        # either the SAME service kind ({#name}) declared twice, or two DIFFERENT
        # services (say a `postgres` and a `compose`) naming the SAME `env_var`,
        # whose URLs collide when a backend merges them into one WorkerEnv. Both
        # refuse loudly, consistent with the loud-failure premise.
        class Duplicate < Error; end

        # Evaluate `source` (read from `path`) and return the ordered
        # declarations. `path` and line 1 give backtraces that point into the
        # user's `.lain/services.rb`, not into this evaluator.
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
        def redis(**) = declare(Services::Redis.new(**))
        def compose(**) = declare(Services::Compose.new(**))

        # An unknown top-level call in the DSL is a typo'd service verb; name it
        # and list what IS known rather than surfacing a bare NoMethodError.
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

        # Every service that injects a var into the lease answers `env_var`
        # (postgres' DATABASE_URL, redis' REDIS_URL, compose's declared var). Two
        # declarations sharing one -- even across DIFFERENT service kinds whose
        # {#name}s differ -- would silently clobber in the merge, so the second
        # refuses loudly and names both culprits.
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
