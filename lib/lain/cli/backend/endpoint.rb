# frozen_string_literal: true

module Lain
  module CLI
    class Backend
      # An `--api-base` that is not a usable http/https endpoint. Raised by
      # {Endpoint#url}, at construction.
      class InvalidEndpoint < Error; end

      # A `--api-base` validated at construction, in its own name, the way
      # {Ceiling} already does for the two ceiling flags.
      #
      # The question asked is deliberately not "does `URI.parse` succeed".
      # For `localhost:11434` -- the ordinary way to leave a scheme off -- it
      # does, reading scheme `localhost`, opaque `11434`, no host, and raising
      # nothing, so the `URI::InvalidURIError` guard this used to lean on never
      # fired for the actual typo and construction ran all the way to the first
      # turn, where Faraday's `build_exclusive_url` called `end_with?` on the
      # nil host and died with a bare `NoMethodError`. What is asked instead is
      # "is there an http/https scheme and a host to send a request to".
      #
      # THE FLAG IS A FIELD, matching {Ceiling}: `--api-base` is the only flag
      # that reaches here today, but a refusal naming none would repeat the
      # mistake {Ceiling}'s docstring already records.
      Endpoint = Data.define(:flag, :value) do
        # @return [String] the base URL, unchanged -- validation checks shape,
        #   it does not normalize
        # @raise [InvalidEndpoint] when the value does not parse as a URI at
        #   all, when it parses but names no host or an empty one (`nil` for
        #   the scheme-less typo, `""` for `http://` and the empty-$OLLAMA_HOST
        #   shape `http:///x`), or when the scheme is not http/https
        def url
          uri = parsed
          raise InvalidEndpoint, hostless_message(uri) if hostless?(uri)
          raise InvalidEndpoint, scheme_message(uri) unless http_scheme?(uri)

          value
        end

        private

        def parsed
          URI.parse(value)
        rescue URI::Error
          raise InvalidEndpoint, "#{flag} #{value.inspect} is not a usable URL"
        end

        def hostless?(uri) = uri.host.to_s.empty?

        def http_scheme?(uri) = %w[http https].include?(uri.scheme)

        # Only the scheme-less typo is told a scheme is required: `http://`
        # has one, and a refusal claiming otherwise sends the operator to fix
        # the half that was right.
        def hostless_message(uri)
          remedy = http_scheme?(uri) ? "name one" : "a scheme is required"
          "#{flag} #{value.inspect} has no host; #{remedy}, e.g. http://localhost:11434"
        end

        def scheme_message(uri)
          "#{flag} #{value.inspect} must be http or https, got #{uri.scheme.inspect}"
        end
      end
    end
  end
end
