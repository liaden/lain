# frozen_string_literal: true

# New code, not a port. Upstream's `Provider` class carries its own registry
# (`providers`/`register`/`resolve`) as class methods, which pushed the class
# past this project's default `Metrics/ClassLength` (100) once the eleven
# leak-site resolutions and their provenance were folded in. Naming and
# resolving providers by slug is a real, separate responsibility from one
# instance's `#complete` round trip, so it is `extend`ed in rather than
# disabled away. Behavior (including leak site 5: registering a provider
# also registers its configuration options) is unchanged.
#
# `providers`/`resolve` were dropped (nothing at runtime resolves a provider
# by slug -- `cli/backend.rb` uses a literal `case`), leaving only
# `#register`. `registered_providers` stays private: it is `#register`'s own
# backing store, not a lookup API.

module Lain
  class Provider
    module HTTP
      class Provider
        # `Provider.extend`s this, so `register` lands as a class method
        # without inflating `Provider`'s own line count.
        module Registry
          # Registering a provider also registers its configuration options
          # (leak site 5, kept -- see provider.rb's header).
          def register(name, provider_class)
            registered_providers[name.to_sym] = provider_class
            Configuration.register_provider_options(provider_class.configuration_options)
          end

          private

          def registered_providers
            @registered_providers ||= {}
          end
        end
      end
    end
  end
end
