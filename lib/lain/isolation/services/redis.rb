# frozen_string_literal: true

module Lain
  module Isolation
    class Services
      # A declared Redis service: a base connection plus the size of the logical
      # DB-index space. A deeply frozen value object (the functional core) --
      # index ALLOCATION is stateful and lives in {DbIndex}'s pool (the
      # imperative shell); this object only names a URL for a given index.
      #
      # `max_databases` is redis's own default of 16 logical DBs (0..15). Index 0
      # is the reserved default, so a worker draws a DISTINCT index from 1..15 --
      # {DbIndex} refuses loudly rather than wrap back onto a used index.
      Redis = Data.define(:env_var, :host, :port, :max_databases) do
        def initialize(env_var: "REDIS_URL", host: "localhost", port: 6379, max_databases: 16)
          super(env_var: env_var.to_s.freeze, host: host.to_s.freeze, port:, max_databases:)
        end

        # The journalable identity (B6 pairs this with the worker key).
        def name = :redis

        # The REDIS_URL a lease injects, selecting logical DB `index`.
        def url(index) = "redis://#{host}:#{port}/#{index}"

        # Claim a distinct index off the shared pool (loud on exhaustion), inject
        # its URL, and hand back the release that returns the index to the pool.
        def provision(context)
          index = context.claim_index(max_databases)
          DbIndex::Provisioned.new(service_name: name, env_var:, url: url(index),
                                   release: -> { context.release_index(index) })
        end
      end
    end
  end
end
