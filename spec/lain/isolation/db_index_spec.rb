# frozen_string_literal: true

# The DB-index isolation strategy: decorates an inner isolation backend and,
# for each service a project declares, provisions a per-worker Postgres DB and
# assigns a distinct Redis DB-index, injecting DATABASE_URL/REDIS_URL into the
# lease's WorkerEnv and reclaiming both on release.
#
# The default suite runs against an INJECTED fake shell factory and a stub Paths
# -- deterministic, no Postgres or Redis needed. The real end-to-end round trip
# is the :integration context at the bottom (guarded on pg/redis being present).
# Records every argv it is asked to run and hands back a fake shell whose exit
# status is scripted -- so a spec asserts the exact createdb/dropdb command
# line, and drives the collision path by scripting a nonzero exit.
class FakeShellFactory
  Shell = Struct.new(:argv, :exitstatus, :stderr) do
    def run_command = self
  end

  def initialize(exit_for: ->(_argv) { 0 }, stderr: "")
    @exit_for = exit_for
    @stderr = stderr
    @calls = []
  end

  attr_reader :calls

  def call(*argv)
    @calls << argv
    Shell.new(argv, @exit_for.call(argv), @stderr)
  end
end

# A recording inner backend: its leases count their own releases, so a spec can
# prove the DECORATED inner lease is reclaimed (or not stranded) independently
# of the service provisioning around it.
class RecordingInner
  Lease = Struct.new(:worker_env, :releases) do
    # Returns the running count (not a boolean) -- a command that records itself,
    # so the spec reads `releases`, and it dodges Naming/PredicateMethod.
    def release = self.releases += 1
  end

  def initialize
    @leases = []
  end

  attr_reader :leases

  def acquire(_worker_id)
    Lease.new(Lain::WorkerEnv.default, 0).tap { |lease| @leases << lease }
  end
end

RSpec.describe Lain::Isolation::DbIndex do
  # A Paths stub whose project_hash is fixed per worker_id, so a command line is
  # exact and two workers key to two different db names.
  def stub_paths
    instance_double(Lain::Paths).tap do |paths|
      allow(paths).to receive(:project_hash) { |worker_id| "hash#{worker_id}" }
    end
  end

  let(:shell) { FakeShellFactory.new }

  def build(services)
    described_class.new(services:, inner: Lain::Isolation::Null.new,
                        paths: stub_paths, shell_out_factory: shell)
  end

  describe "no declared services" do
    subject(:backend) { build([]) }

    it "degrades to a code-only lease: no service vars injected, release is inner-only" do
      lease = backend.acquire("w1")

      expect(lease.worker_env.env).not_to have_key("DATABASE_URL")
      expect(lease.worker_env.env).not_to have_key("REDIS_URL")
      expect(shell.calls).to be_empty
      expect(lease.release).to be(true)
    end
  end

  describe "a declared Postgres service" do
    let(:postgres) { Lain::Isolation::Services::Postgres.new }
    subject(:backend) { build([postgres]) }

    it "creates a per-worker DB and points DATABASE_URL at it" do
      lease = backend.acquire("w1")

      expect(shell.calls).to include(%w[createdb lain_worker_hashw1])
      expect(lease.worker_env.env.fetch("DATABASE_URL")).to eq("postgresql:///lain_worker_hashw1")
    end

    it "drops the database on release, with --if-exists (an already-gone DB is the goal met)" do
      lease = backend.acquire("w1")
      lease.release

      expect(shell.calls).to include(%w[dropdb --if-exists lain_worker_hashw1])
    end

    it "stays loud when dropdb fails for a real reason (permission denied), despite --if-exists" do
      denied = FakeShellFactory.new(exit_for: ->(argv) { argv.first == "dropdb" ? 1 : 0 }, stderr: "permission denied")
      backend = described_class.new(services: [postgres], inner: Lain::Isolation::Null.new,
                                    paths: stub_paths, shell_out_factory: denied)
      lease = backend.acquire("w1")

      expect { lease.release }.to raise_error(Lain::Isolation::DbIndex::Refused, /permission denied/)
    end

    it "refuses LOUDLY when createdb exits nonzero (a name collision -- never reuse a shared DB)" do
      collide = FakeShellFactory.new(exit_for: ->(argv) { argv.first == "createdb" ? 1 : 0 }, stderr: "already exists")
      backend = described_class.new(services: [postgres], inner: Lain::Isolation::Null.new,
                                    paths: stub_paths, shell_out_factory: collide)

      expect do
        backend.acquire("w1")
      end.to raise_error(Lain::Isolation::DbIndex::Refused,
                         /createdb.*collision|collision.*createdb|createdb/i)
    end

    it "releases the inner lease when provisioning fails -- never strands a worktree" do
      inner = RecordingInner.new
      collide = FakeShellFactory.new(exit_for: ->(argv) { argv.first == "createdb" ? 1 : 0 })
      backend = described_class.new(services: [postgres], inner:, paths: stub_paths, shell_out_factory: collide)

      expect { backend.acquire("w1") }.to raise_error(Lain::Isolation::DbIndex::Refused)
      expect(inner.leases.map(&:releases)).to eq([1])
    end
  end

  describe "a declared Redis service" do
    let(:redis) { Lain::Isolation::Services::Redis.new }
    subject(:backend) { build([redis]) }

    it "gives two workers distinct Redis DB-indices off the default 0" do
      one = backend.acquire("w1")
      two = backend.acquire("w2")

      expect(one.worker_env.env.fetch("REDIS_URL")).to eq("redis://localhost:6379/1")
      expect(two.worker_env.env.fetch("REDIS_URL")).to eq("redis://localhost:6379/2")
    end

    it "returns a released index to the pool for reuse" do
      one = backend.acquire("w1")
      one.release
      two = backend.acquire("w2")

      expect(two.worker_env.env.fetch("REDIS_URL")).to eq("redis://localhost:6379/1")
    end

    it "refuses LOUDLY on pool exhaustion rather than wrapping into a used index" do
      backend = build([Lain::Isolation::Services::Redis.new(max_databases: 2)])
      backend.acquire("w1") # claims the sole index (1), leaving none

      expect { backend.acquire("w2") }.to raise_error(Lain::Isolation::DbIndex::Refused, /exhaust/i)
    end
  end

  describe "both services declared" do
    subject(:backend) do
      build([Lain::Isolation::Services::Postgres.new, Lain::Isolation::Services::Redis.new])
    end

    it "injects both URLs into one lease's WorkerEnv" do
      lease = backend.acquire("w1")

      expect(lease.worker_env.env.fetch("DATABASE_URL")).to eq("postgresql:///lain_worker_hashw1")
      expect(lease.worker_env.env.fetch("REDIS_URL")).to eq("redis://localhost:6379/1")
    end

    it "rolls back the created DB when a later service fails to provision" do
      # Redis capped at 1 usable index; a second acquire exhausts the pool AFTER
      # createdb ran, so the created DB must be dropped on the failed acquire.
      backend = build([Lain::Isolation::Services::Postgres.new,
                       Lain::Isolation::Services::Redis.new(max_databases: 2)])
      backend.acquire("w1")
      shell.calls.clear

      expect { backend.acquire("w2") }.to raise_error(Lain::Isolation::DbIndex::Refused)
      expect(shell.calls).to include(%w[dropdb --if-exists lain_worker_hashw2])
    end

    it "frees every service on release even when one teardown raises, then re-raises loudly" do
      # Postgres is declared FIRST, so its dropdb runs first on release; scripting
      # it to fail proves the Redis index behind it is still freed (a later worker
      # reuses index 1) AND that the failure still propagates.
      dropdb_fails = FakeShellFactory.new(exit_for: ->(argv) { argv.first == "dropdb" ? 1 : 0 })
      backend = described_class.new(
        services: [Lain::Isolation::Services::Postgres.new, Lain::Isolation::Services::Redis.new],
        inner: Lain::Isolation::Null.new, paths: stub_paths, shell_out_factory: dropdb_fails
      )
      lease = backend.acquire("w1")

      expect { lease.release }.to raise_error(Lain::Isolation::DbIndex::Refused, /dropdb/)
      expect(backend.acquire("w2").worker_env.env.fetch("REDIS_URL")).to eq("redis://localhost:6379/1")
    end
  end

  # The real thing: a live Postgres and Redis. Opt-in via the dedicated :services
  # tag (LAIN_SERVICES=1 -- see spec/support/tags.rb); additionally SKIPS when the
  # CLI tools are absent, so an opted-in run on a machine without pg/redis reports
  # a gap, not a failure.
  describe "end to end", :services do
    before do
      %w[createdb dropdb redis-cli].each do |tool|
        skip("#{tool} not on PATH -- install postgres/redis to run this :services spec") \
          unless system("sh", "-c", "command -v #{tool}", out: File::NULL, err: File::NULL)
      end
    end

    it "creates a real per-worker database reachable at DATABASE_URL, then drops it" do
      backend = described_class.new(services: [Lain::Isolation::Services::Postgres.new])
      lease = backend.acquire("itest-#{Process.pid}")
      url = lease.worker_env.env.fetch("DATABASE_URL")
      db = url.split("/").last

      expect(system("sh", "-c", "psql -lqt | cut -d'|' -f1 | grep -qw #{db}")).to be(true)

      lease.release
      expect(system("sh", "-c", "psql -lqt | cut -d'|' -f1 | grep -qw #{db}")).to be(false)
    end
  end
end
