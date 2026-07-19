# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# The `.lain/services.rb` DSL: a project declares the backing services its
# workers each need an isolated instance of. Rails-like -- the file is the
# user's own Ruby, evaluated with no sandbox -- and every declaration is a
# deeply frozen value object (the functional core; all side effects happen at
# lease time in DbIndex).
RSpec.describe Lain::Isolation::Services do
  # Writes a `.lain/services.rb` under a throwaway root and loads it.
  def load_services(source)
    Dir.mktmpdir("lain-services") do |root|
      FileUtils.mkdir_p(File.join(root, ".lain"))
      File.write(File.join(root, ".lain", "services.rb"), source)
      return described_class.load(root:)
    end
  end

  describe ".load" do
    it "returns an empty, enumerable collection when no .lain/services.rb exists" do
      Dir.mktmpdir("lain-empty") do |root|
        services = described_class.load(root:)

        expect(services).to be_empty
        expect(services.to_a).to eq([])
      end
    end

    it "declares a Postgres service from a bare `postgres` line" do
      services = load_services("postgres\n")

      expect(services.to_a.map(&:name)).to eq([:postgres])
      expect(services.first).to be_a(Lain::Isolation::Services::Postgres)
    end

    it "declares a Redis service from a bare `redis` line" do
      services = load_services("redis\n")

      expect(services.to_a.map(&:name)).to eq([:redis])
      expect(services.first).to be_a(Lain::Isolation::Services::Redis)
    end

    it "declares both services in declaration order" do
      services = load_services("postgres\nredis\n")

      expect(services.map(&:name)).to eq(%i[postgres redis])
    end

    it "threads declared options through to the service value object" do
      services = load_services(%(postgres host: "db.internal", user: "worker", prefix: "app"\n))
      postgres = services.first

      expect(postgres.host).to eq("db.internal")
      expect(postgres.user).to eq("worker")
      expect(postgres.prefix).to eq("app")
    end

    it "is deeply frozen -- the collection and its declarations" do
      services = load_services("postgres\nredis\n")

      expect(services).to be_frozen
      expect(services.map(&:frozen?)).to all(be(true))
    end

    it "refuses an unknown service verb loudly, naming the known services" do
      expect { load_services("mongodb\n") }
        .to raise_error(Lain::Isolation::Services::Builder::Unknown, /mongodb.*postgres.*redis/m)
    end

    it "refuses a duplicate service declaration loudly (a second one would silently clobber its URL)" do
      expect { load_services("postgres\npostgres\n") }
        .to raise_error(Lain::Isolation::Services::Builder::Duplicate, /postgres/)
    end
  end

  describe Lain::Isolation::Services::Postgres do
    subject(:postgres) { described_class.new }

    it "names the per-worker database `<prefix>_<worker_key>`" do
      expect(postgres.database_name("abc123")).to eq("lain_worker_abc123")
    end

    it "builds a bare `createdb <db>` command line when no connection identity is set" do
      expect(postgres.createdb_command("abc123")).to eq(%w[createdb lain_worker_abc123])
    end

    it "drops with --if-exists so an already-gone DB on release is the goal met, not a failure" do
      expect(postgres.dropdb_command("abc123")).to eq(%w[dropdb --if-exists lain_worker_abc123])
    end

    it "builds a libpq-default DATABASE_URL that points at the per-worker db" do
      expect(postgres.url("abc123")).to eq("postgresql:///lain_worker_abc123")
    end

    it "adds -h/-p/-U flags and a full authority when a connection identity is declared" do
      pg = described_class.new(host: "db.internal", port: 5433, user: "worker")

      expect(pg.createdb_command("abc123"))
        .to eq(["createdb", "-h", "db.internal", "-p", "5433", "-U", "worker", "lain_worker_abc123"])
      expect(pg.url("abc123")).to eq("postgresql://worker@db.internal:5433/lain_worker_abc123")
    end

    it "never embeds a password in the URL (a password lives in PGPASSWORD/pgpass, never the journalable URL)" do
      pg = described_class.new(host: "db", user: "worker")

      # No `user:password@` form -- the authority carries a username at most.
      expect(pg.url("abc123")).not_to match(%r{//[^/@]*:[^/@]*@})
      expect(pg.url("abc123")).to eq("postgresql://worker@db/lain_worker_abc123")
    end
  end

  describe Lain::Isolation::Services::Redis do
    subject(:redis) { described_class.new }

    it "defaults to 16 databases (the redis default) so index 0 is the reserved default" do
      expect(redis.max_databases).to eq(16)
    end

    it "builds a REDIS_URL selecting the given DB-index" do
      expect(redis.url(3)).to eq("redis://localhost:6379/3")
    end
  end
end
