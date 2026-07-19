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
        VERBS = %i[postgres redis].freeze

        # An unrecognized service verb in `.lain/services.rb`. The DSL is a stable
        # surface, so a typo fails LOUDLY and named rather than as a bare
        # NoMethodError. Named per the error-taxonomy convention, next to the
        # evaluator that raises it.
        class Unknown < Error; end

        # A second declaration of a service already declared: it would silently
        # clobber the first's injected URL in the lease, so -- consistent with the
        # loud-failure premise -- it refuses.
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

        # An unknown top-level call in the DSL is a typo'd service verb; name it
        # and list what IS known rather than surfacing a bare NoMethodError.
        def method_missing(name, *, **)
          raise Unknown, "unknown service #{name.inspect} in .lain/services.rb; " \
                         "known services: #{VERBS.join(", ")}"
        end

        def respond_to_missing?(name, include_private = false) = VERBS.include?(name) || super

        private

        def declare(service)
          if @declarations.any? { |existing| existing.name == service.name }
            raise Duplicate, "duplicate #{service.name} service in .lain/services.rb; " \
                             "declare each service at most once"
          end

          @declarations << service
          service
        end
      end
    end
  end
end
