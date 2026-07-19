# frozen_string_literal: true

module Lain
  module Isolation
    class Services
      # A declared Postgres service: enough identity to provision a per-worker
      # database and name a URL that points at it. A deeply frozen value object
      # (the functional core) -- every method is pure; the actual `createdb`
      # runs in {DbIndex}, the imperative shell, at lease time.
      #
      # A PASSWORD NEVER ENTERS THE URL. The optional `user` rides the URL
      # authority, but a password does not -- it belongs in PGPASSWORD/pgpass,
      # never in a string that lands in a WorkerEnv and, later (B6), a journalled
      # lease event. The journalable identity of a provisioned service is its
      # {#name} plus the worker key, never this URL.
      Postgres = Data.define(:env_var, :prefix, :host, :port, :user) do
        def initialize(env_var: "DATABASE_URL", prefix: "lain_worker", host: nil, port: nil, user: nil)
          super(env_var: env_var.to_s.freeze, prefix: prefix.to_s.freeze,
                host: host&.to_s&.freeze, port:, user: user&.to_s&.freeze)
        end

        # The journalable identity (B6 pairs this with the worker key -- never
        # the URL, which carries connection identity).
        def name = :postgres

        # The per-worker database, keyed off the worker hash: `lain_worker_<hash>`.
        def database_name(worker_key) = "#{prefix}_#{worker_key}"

        def createdb_command(worker_key) = ["createdb", *connection_flags, database_name(worker_key)]

        # `--if-exists` because on RELEASE an already-gone database is the goal
        # met, not a failure -- release stays loud only on a REAL failure (a
        # nonzero exit for permission, connection, etc.), which {#drop} still
        # raises on.
        def dropdb_command(worker_key) = ["dropdb", "--if-exists", *connection_flags, database_name(worker_key)]

        # The DATABASE_URL a lease injects. With no connection identity declared
        # this is `postgresql:///<db>`, whose empty authority makes libpq resolve
        # host/port/user from its own defaults -- the SAME defaults a bare
        # `createdb <db>` used, so the URL points at exactly what was created.
        def url(worker_key) = "postgresql://#{authority}/#{database_name(worker_key)}"

        # Provision imperatively against the lease-time shell (see {DbIndex}),
        # then hand back the injected var and the drop that reclaims it. A
        # nonzero createdb exit is almost always a name collision with a
        # pre-existing database; refusing loudly here is what keeps a worker off
        # a shared DB.
        def provision(context)
          key = context.worker_key
          create(context, key)
          DbIndex::Provisioned.new(service_name: name, env_var:, url: url(key), release: -> { drop(context, key) })
        end

        private

        def create(context, key)
          created = context.run(*createdb_command(key))
          return if created.exitstatus.zero?

          raise DbIndex::Refused, "createdb #{database_name(key).inspect} failed (exit #{created.exitstatus}) -- " \
                                  "likely a name collision with an existing database; refusing to reuse a shared " \
                                  "DB: #{created.stderr.strip}"
        end

        def drop(context, key)
          dropped = context.run(*dropdb_command(key))
          return if dropped.exitstatus.zero?

          raise DbIndex::Refused, "dropdb #{database_name(key).inspect} failed (exit #{dropped.exitstatus}): " \
                                  "#{dropped.stderr.strip}"
        end

        # `-h/-p/-U` flags for each piece of connection identity that is set;
        # empty when none is (the bare `createdb <db>` the card specifies). No PG*
        # env scrub (unlike B2's git-context scrub): these explicit flags already
        # take precedence over any inherited PG* connection var, and PGPASSWORD is
        # deliberately left to reach libpq for auth.
        def connection_flags
          { "-h" => host, "-p" => port, "-U" => user }.flat_map { |flag, value| value ? [flag, value.to_s] : [] }
        end

        def authority
          credentials = user ? "#{user}@" : ""
          host_port = host ? [host, port].compact.join(":") : ""
          "#{credentials}#{host_port}"
        end
      end
    end
  end
end
