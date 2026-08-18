# frozen_string_literal: true

module Lain
  module CLI
    class Backend
      # An `--api-base` that is not a usable http/https endpoint. Raised by
      # {Endpoint#url}, at construction, for the same reason {InvalidCeiling}
      # is: `localhost:11434` -- the scheme-less typo -- is a VALID URI, so
      # the `URI::InvalidURIError` guard the codebase used to rely on never
      # fires, and the failure used to surface as a bare `NoMethodError` from
      # inside Faraday on the first turn instead.
      class InvalidEndpoint < Error; end

      # A `--api-base` validated at construction, in its own name, the way
      # {Ceiling} already does for the two ceiling flags.
      #
      # `localhost:11434` -- the ordinary way to leave a scheme off -- is a
      # VALID URI: `URI.parse` reads it as scheme `localhost`, opaque
      # `11434`, no host, and raises nothing. So the `URI::InvalidURIError`
      # guard the codebase used to lean on never fired for the actual typo,
      # and construction succeeded all the way to the first turn, where
      # Faraday's `build_exclusive_url` called `end_with?` on the nil host
      # and died with a bare `NoMethodError` naming an internal collaborator.
      # The question this asks is deliberately not "does `URI.parse`
      # succeed" -- it does, for the typo -- but "is there an http/https
      # scheme and a host to send a request to".
      #
      # THE FLAG IS A FIELD, matching {Ceiling}: `--api-base` is currently
      # the only flag that reaches here, but a refusal that named neither
      # would be the same mistake {Ceiling}'s docstring already recorded once.
      Endpoint = Data.define(:flag, :value) do
        # @return [String] the base URL, unchanged -- validation checks
        #   shape, it does not normalize
        # @raise [InvalidEndpoint] when the value does not parse as a URI at
        #   all, when it parses but names no host or an empty one (`nil` for
        #   the scheme-less typo, `""` for `http://` and the empty-$OLLAMA_HOST
        #   shape `http:///x`), or when the scheme is not http/https
        def url
          uri = parsed
          raise InvalidEndpoint, hostless_message if hostless?(uri)
          raise InvalidEndpoint, scheme_message(uri) unless http_scheme?(uri)

          value
        end

        private

        def parsed
          URI.parse(value)
        rescue URI::Error
          raise InvalidEndpoint, "#{flag} #{value.inspect} is not a usable URL"
        end

        # `nil` for the scheme-less typo (`localhost:11434`), `""` for
        # `http://` and the empty-$OLLAMA_HOST shape `http:///x` -- both mean
        # there is nowhere to send a request.
        def hostless?(uri) = uri.host.to_s.empty?

        def http_scheme?(uri) = %w[http https].include?(uri.scheme)

        def hostless_message
          "#{flag} #{value.inspect} has no host; a scheme is required, e.g. http://localhost:11434"
        end

        def scheme_message(uri)
          "#{flag} #{value.inspect} must be http or https, got #{uri.scheme.inspect}"
        end
      end
    end
  end
end
