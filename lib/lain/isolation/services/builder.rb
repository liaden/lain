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
        VERBS = %i[postgres redis compose].freeze

        # An unrecognized service verb. The DSL is a stable surface, so a typo
        # fails LOUDLY and named rather than as a bare NoMethodError.
        class Unknown < Error; end

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
        def redis(**) = declare(Services::Redis.new(**))
        def compose(**) = declare(Services::Compose.new(**))

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
