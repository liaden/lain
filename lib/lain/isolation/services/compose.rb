# frozen_string_literal: true

module Lain
  module Isolation
    class Services
      # A declared compose service: enough identity to find ONE service's
      # published host port in a per-worker `docker compose` stack and name the
      # URL a worker reaches it at. A deeply frozen value object (the functional
      # core) -- every method is pure; the `docker compose port` call and the
      # stack lifecycle run in {Compose}, the imperative shell, at lease time.
      #
      # PORT DISCOVERY IS THE SERVICE'S OWN CONCERN (dogfooded, per the plan's
      # compose decision): {#discover} is the seam the {Compose} backend invokes
      # per declared service, defaulting to `docker compose port <service>
      # <container_port>` via the injected context. A service that discovers its
      # port differently overrides {#discover}; the backend never special-cases
      # a mapping. `container_port` is the port INSIDE the container; the host
      # port compose publishes it on is what discovery reads back.
      #
      # CREDENTIALS STAY OUT OF THE URL. Like {Postgres}, the constructed URL is
      # `scheme://host:<published_port>` -- no password -- and the journalable
      # identity is {#name} plus the worker key, never the URL.
      Compose = Data.define(:service, :container_port, :env_var, :scheme, :host) do
        def initialize(service:, container_port:, env_var:, scheme: "tcp", host: "localhost")
          super(service: service.to_s.freeze, container_port:, env_var: env_var.to_s.freeze,
                scheme: scheme.to_s.freeze, host: host.to_s.freeze)
        end

        # The journalable identity (B6 pairs this with the worker key). Namespaced
        # per compose service so two declarations (`web`, `db`) are distinct
        # declarations rather than a {Builder::Duplicate} collision.
        def name = :"compose_#{service}"

        # The URL a lease injects for `published_port` (the host port compose
        # mapped this service's `container_port` to).
        def url(published_port) = "#{scheme}://#{host}:#{published_port}"

        # Read this service's published host port through the lease-time context
        # (see {Compose::Stack#published_port}) and hand back the var and URL the
        # backend injects. The context owns running `docker compose port`; this
        # object owns which service+port to ask for and how to shape the URL.
        def discover(context)
          published_port = context.published_port(service, container_port)
          # Isolation::Compose (the backend), not this Services::Compose: a bare
          # `Compose` here resolves lexically to THIS Data class.
          Isolation::Compose::Published.new(service_name: name, env_var:, url: url(published_port))
        end
      end
    end
  end
end
