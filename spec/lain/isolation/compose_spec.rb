# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# The Compose isolation strategy: decorates an inner backend and, for a project
# declaring compose services, brings up a namespaced `docker compose` stack per
# worker (`-p lain_<hash>`), reads back the published ports each declared
# service discovers, injects the service URLs into the lease's WorkerEnv, and
# tears the stack down with its volumes (`down -v`) on release.
#
# The default suite runs against an INJECTED fake shell factory and a stub Paths
# -- deterministic, no docker daemon needed. It scripts each subcommand's exit
# and stdout, so a spec asserts the exact `docker compose -p ... up -d / port /
# down -v` command lines and drives the reap/refuse paths by scripting failure.
# The real end-to-end round trip is the :services context at the bottom.
class FakeComposeShell
  Result = Struct.new(:argv, :exitstatus, :stdout, :stderr) do
    def run_command = self
  end

  # `script` maps an argv to `{exitstatus:, stdout:, stderr:}`; the default is a
  # happy stack (nothing running, up/port/down all succeed).
  def initialize(&script)
    @script = script || ->(_argv) { {} }
    @calls = []
    @environments = []
  end

  attr_reader :calls, :environments

  def call(*argv, environment: nil)
    @calls << argv
    @environments << environment
    outcome = @script.call(argv)
    Result.new(argv, outcome.fetch(:exitstatus, 0), outcome.fetch(:stdout, ""), outcome.fetch(:stderr, ""))
  end

  # The docker-compose subcommand (`up`/`ps`/`port`/`down`) is the first token
  # after `-p <proj> -f <file>`.
  def self.subcommand(argv) = argv[6]
end

# A recording inner backend (mirrors the DbIndex spec): its leases count their
# own releases, so a spec proves the DECORATED inner lease is reclaimed -- never
# stranded -- independently of the stack lifecycle around it.
class RecordingComposeInner
  def initialize
    @leases = []
  end

  attr_reader :leases

  def acquire(_worker_id)
    Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.default).tap { |lease| @leases << lease }
  end
end

RSpec.describe Lain::Isolation::Compose do
  # A Paths stub whose project_hash is fixed per worker_id, so a project name is
  # exact and two workers key to two different `-p` names.
  def stub_paths
    instance_double(Lain::Paths).tap do |paths|
      allow(paths).to receive(:project_hash) { |worker_id| "hash#{worker_id}" }
    end
  end

  let(:compose_file) { "/proj/compose.yml" }

  # A happy fake shell: nothing already running (`ps -q` empty), `up`/`down`
  # succeed, and `port` publishes each service on a scripted host port.
  def happy_shell(ports: Hash.new("0.0.0.0:32769"))
    FakeComposeShell.new do |argv|
      case FakeComposeShell.subcommand(argv)
      in "port" then { stdout: ports[argv[7]] }
      in "ps" then { stdout: "" }
      else {}
      end
    end
  end

  def build(services, shell:, inner: Lain::Isolation::Null.new)
    described_class.new(services:, inner:, paths: stub_paths,
                        compose_file:, shell_out_factory: shell)
  end

  def compose_service(**) = Lain::Isolation::Services::Compose.new(**)

  describe "the compose DSL verb" do
    def declare(source) = Lain::Isolation::Services::Builder.build(source, "(compose_spec)")

    it "declares a Compose service carrying its service, container port, and env var" do
      declared = declare(%(compose service: "db", container_port: 5432, env_var: "DATABASE_URL"\n))

      expect(declared.map(&:service)).to eq(["db"])
      expect(declared.first.container_port).to eq(5432)
      expect(declared.first.env_var).to eq("DATABASE_URL")
    end

    it "names each declaration per-service, so two distinct services coexist" do
      declared = declare(<<~DSL)
        compose service: "web", container_port: 80, env_var: "WEB_URL"
        compose service: "db", container_port: 5432, env_var: "DATABASE_URL"
      DSL

      expect(declared.map(&:name)).to eq(%i[compose_web compose_db])
    end

    it "refuses a duplicate declaration of the same service loudly" do
      expect do
        declare(<<~DSL)
          compose service: "db", container_port: 5432, env_var: "DATABASE_URL"
          compose service: "db", container_port: 5433, env_var: "OTHER_URL"
        DSL
      end.to raise_error(Lain::Isolation::Services::Builder::Duplicate, /compose_db/)
    end

    it "refuses two DISTINCT compose services sharing an env var (they clobber in the lease)" do
      expect do
        declare(<<~DSL)
          compose service: "a", container_port: 80, env_var: "URL"
          compose service: "b", container_port: 81, env_var: "URL"
        DSL
      end.to raise_error(Lain::Isolation::Services::Builder::Duplicate, /URL/)
    end

    it "refuses an env-var collision across DIFFERENT service kinds (postgres vs compose)" do
      expect do
        declare(<<~DSL)
          postgres
          compose service: "db", container_port: 5432, env_var: "DATABASE_URL"
        DSL
      end.to raise_error(Lain::Isolation::Services::Builder::Duplicate, /DATABASE_URL/)
    end
  end

  describe Lain::Isolation::Services::Compose do
    subject(:service) do
      described_class.new(service: "db", container_port: 5432, env_var: "DATABASE_URL", scheme: "postgres")
    end

    it "is a deeply frozen value object" do
      expect(service).to be_frozen
      expect(Ractor.shareable?(service)).to be(true)
    end

    it "builds a scheme://host:port URL from a discovered published port" do
      expect(service.url(32_769)).to eq("postgres://localhost:32769")
    end

    it "discovers its published port through the context and wraps it as a Published outcome" do
      context = instance_double(Lain::Isolation::Compose::Stack)
      allow(context).to receive(:published_port).with("db", 5432).and_return(32_769)

      published = service.discover(context)

      expect(published.service_name).to eq(:compose_db)
      expect(published.env_var).to eq("DATABASE_URL")
      expect(published.url).to eq("postgres://localhost:32769")
    end
  end

  describe "no declared compose services" do
    it "degrades to a code-only lease: no docker calls, no service vars, inner-only release" do
      shell = happy_shell
      backend = build([], shell:)
      lease = backend.acquire("w1")

      expect(shell.calls).to be_empty
      expect(lease.worker_env.env).not_to have_key("DATABASE_URL")
      expect(lease.release).to be(true)
    end
  end

  describe "a declared compose service" do
    let(:db) { compose_service(service: "db", container_port: 5432, env_var: "DATABASE_URL", scheme: "postgres") }

    it "brings up a namespaced stack and points the env at the published port" do
      shell = happy_shell(ports: { "db" => "0.0.0.0:32769" })
      lease = build([db], shell:).acquire("w1")

      expect(shell.calls).to include(%w[docker compose -p lain_hashw1 -f /proj/compose.yml up -d])
      expect(shell.calls).to include(%w[docker compose -p lain_hashw1 -f /proj/compose.yml port db 5432])
      expect(lease.worker_env.env.fetch("DATABASE_URL")).to eq("postgres://localhost:32769")
    end

    it "probes for a pre-existing stack BEFORE up, so it never co-opts one" do
      shell = happy_shell
      build([db], shell:).acquire("w1")
      subcommands = shell.calls.map { |argv| FakeComposeShell.subcommand(argv) }

      expect(subcommands.index("ps")).to be < subcommands.index("up")
    end

    it "tears the stack down with its volumes on release, then releases the inner lease" do
      inner = RecordingComposeInner.new
      shell = happy_shell
      lease = build([db], shell:, inner:).acquire("w1")
      shell.calls.clear
      lease.release

      expect(shell.calls).to include(%w[docker compose -p lain_hashw1 -f /proj/compose.yml down -v])
      expect(inner.leases.map(&:released?)).to eq([true])
    end

    it "scrubs COMPOSE_PROJECT_NAME/COMPOSE_FILE so ambient config never redirects our -p/-f" do
      shell = happy_shell
      build([db], shell:).acquire("w1")

      expect(shell.environments).to all(include("COMPOSE_PROJECT_NAME" => nil, "COMPOSE_FILE" => nil))
    end
  end

  describe "distinct namespacing per worker" do
    let(:db) { compose_service(service: "db", container_port: 5432, env_var: "DATABASE_URL", scheme: "tcp") }

    it "gives two workers distinct -p project names" do
      shell = happy_shell
      backend = build([db], shell:)
      backend.acquire("w1")
      backend.acquire("w2")
      projects = shell.calls.select { |argv| FakeComposeShell.subcommand(argv) == "up" }.map { |argv| argv[3] }

      expect(projects).to eq(%w[lain_hashw1 lain_hashw2])
    end
  end

  describe "a pre-existing stack under the namespaced name (not ours)" do
    let(:db) { compose_service(service: "db", container_port: 5432, env_var: "DATABASE_URL", scheme: "tcp") }

    # ps -q returns a container id: the project name is already occupied and we
    # did not create it in THIS acquire, so we refuse rather than up-and-later
    # `down -v` a stack we cannot prove is ours.
    def occupied_shell
      FakeComposeShell.new do |argv|
        FakeComposeShell.subcommand(argv) == "ps" ? { stdout: "abc123def456\n" } : {}
      end
    end

    it "refuses LOUDLY and never brings up or tears down the foreign stack" do
      shell = occupied_shell
      expect { build([db], shell:).acquire("w1") }
        .to raise_error(described_class::Refused, /already.*running|refus/i)

      subcommands = shell.calls.map { |argv| FakeComposeShell.subcommand(argv) }
      expect(subcommands).not_to include("up")
      expect(subcommands).not_to include("down")
    end

    it "releases the inner lease on that refusal -- never strands a worktree" do
      inner = RecordingComposeInner.new
      backend = described_class.new(services: [db], inner:, paths: stub_paths,
                                    compose_file:, shell_out_factory: occupied_shell)

      expect { backend.acquire("w1") }.to raise_error(described_class::Refused)
      expect(inner.leases.map(&:released?)).to eq([true])
    end
  end

  describe "a partial or failed up" do
    let(:db) { compose_service(service: "db", container_port: 5432, env_var: "DATABASE_URL", scheme: "tcp") }

    it "reaps the partial stack with down -v when up fails, then releases inner" do
      inner = RecordingComposeInner.new
      up_fails = FakeComposeShell.new do |argv|
        FakeComposeShell.subcommand(argv) == "up" ? { exitstatus: 1, stderr: "boom" } : {}
      end
      backend = described_class.new(services: [db], inner:, paths: stub_paths,
                                    compose_file:, shell_out_factory: up_fails)

      expect { backend.acquire("w1") }.to raise_error(described_class::Refused, /up.*failed/i)
      subcommands = up_fails.calls.map { |argv| FakeComposeShell.subcommand(argv) }
      expect(subcommands).to include("down")
      expect(inner.leases.map(&:released?)).to eq([true])
    end

    it "reaps the stack when a declared port is not published, then refuses loudly" do
      unpublished = FakeComposeShell.new do |argv|
        # port -> "" drives the unpublished refusal; ps -> "" keeps it un-occupied.
        %w[port ps].include?(FakeComposeShell.subcommand(argv)) ? { stdout: "" } : {}
      end

      expect { build([db], shell: unpublished).acquire("w1") }
        .to raise_error(described_class::Refused, /publish/i)
      subcommands = unpublished.calls.map { |argv| FakeComposeShell.subcommand(argv) }
      expect(subcommands).to include("down")
    end
  end

  describe "a probe that could not run (docker daemon down)" do
    let(:db) { compose_service(service: "db", container_port: 5432, env_var: "DATABASE_URL", scheme: "tcp") }

    # A nonzero `ps` proves NOTHING -- it must not read as "unoccupied" and let
    # up adopt (then `down -v`) a pre-existing stack. It refuses with the real
    # cause, issues NO further command (no teardown region entered), and still
    # reclaims the inner lease.
    it "refuses with the real ps failure, issues no further command, and releases inner" do
      inner = RecordingComposeInner.new
      ps_fails = FakeComposeShell.new do |argv|
        if FakeComposeShell.subcommand(argv) == "ps"
          { exitstatus: 1, stderr: "Cannot connect to the Docker daemon" }
        else
          {}
        end
      end
      backend = described_class.new(services: [db], inner:, paths: stub_paths,
                                    compose_file:, shell_out_factory: ps_fails)

      expect { backend.acquire("w1") }.to raise_error(described_class::Refused, /ps.*Docker daemon/i)
      expect(ps_fails.calls.map { |argv| FakeComposeShell.subcommand(argv) }).to eq(["ps"])
      expect(inner.leases.map(&:released?)).to eq([true])
    end
  end

  describe "the daemon-var snapshot at acquire" do
    let(:db) { compose_service(service: "db", container_port: 5432, env_var: "DATABASE_URL", scheme: "tcp") }

    # The safety probe, up, and the release `down -v` can be minutes apart; a
    # mid-lease DOCKER_HOST change must NOT split the probe from the teardown, so
    # the acquire-time daemon is pinned to every call -- including release.
    it "pins DOCKER_HOST to its acquire-time value for every call, even after a mid-lease change" do
      env = { "DOCKER_HOST" => "tcp://acquire-time:2375" }
      shell = happy_shell
      backend = described_class.new(services: [db], inner: Lain::Isolation::Null.new,
                                    paths: stub_paths, compose_file:, shell_out_factory: shell, env:)
      lease = backend.acquire("w1")
      env["DOCKER_HOST"] = "tcp://changed:2375" # a mid-lease change to the source env
      lease.release

      expect(shell.environments).to all(include("DOCKER_HOST" => "tcp://acquire-time:2375"))
      expect(shell.calls.map { |argv| FakeComposeShell.subcommand(argv) }).to include("down")
    end
  end

  describe Lain::Isolation::Compose::Stack do
    # `docker compose port` prints one host:port mapping per line; the published
    # port is the FIRST non-zero one. `rpartition` over the whole blob silently
    # took the LAST line and mis-reported a differing dual-bind.
    def stack(port_output)
      shell = FakeComposeShell.new do |argv|
        FakeComposeShell.subcommand(argv) == "port" ? { stdout: port_output } : {}
      end
      described_class.new(project: "lain_x", compose_file: "/c.yml", shell_out_factory: shell)
    end

    it "takes the first non-zero host port from a differing dual-bind, not the last line" do
      expect(stack("0.0.0.0:49153\n[::]:49155").published_port("db", 5432)).to eq(49_153)
    end

    it "parses an IPv6-only mapping" do
      expect(stack("[::]:49153").published_port("db", 5432)).to eq(49_153)
    end

    it "refuses loudly when nothing is published (empty output)" do
      expect { stack("").published_port("db", 5432) }
        .to raise_error(Lain::Isolation::Compose::Refused, /publish/i)
    end

    it "skips a :0 (unpublished) line and takes the next real port" do
      expect(stack("0.0.0.0:0\n[::]:49153").published_port("db", 5432)).to eq(49_153)
    end
  end

  # The real thing: a live docker daemon and a throwaway compose file. Opt-in via
  # the :services tag (LAIN_SERVICES=1 -- see spec/support/tags.rb); additionally
  # SKIPS when docker compose is unavailable, so an opted-in run on a machine
  # without docker reports a gap, not a failure. Reuses :services (not a new tag)
  # because it already means "provisions a real external service via CLI, skips
  # when absent" -- docker compose is exactly that.
  describe "end to end", :services do
    around do |example|
      Dir.mktmpdir("lain-compose") do |root|
        File.write(File.join(root, "compose.yml"), <<~YAML)
          services:
            cache:
              image: redis:7-alpine
              ports:
                - "6379"
        YAML
        @root = root
        example.run
      end
    end

    before do
      skip("docker compose unavailable -- install docker to run this :services spec") \
        unless system("docker", "compose", "version", out: File::NULL, err: File::NULL)
    end

    it "brings up a real stack reachable at the published port, then tears it down with volumes" do
      backend = described_class.new(
        services: [Lain::Isolation::Services::Compose.new(service: "cache", container_port: 6379,
                                                          env_var: "REDIS_URL", scheme: "redis")],
        project_root: @root
      )
      lease = backend.acquire("itest-#{Process.pid}")
      url = lease.worker_env.env.fetch("REDIS_URL")
      port = url.split(":").last

      expect(port.to_i).to be > 0

      lease.release
      project = "lain_#{Lain::Paths.new.project_hash("itest-#{Process.pid}")}"
      expect(`docker compose -p #{project} ps -q`.strip).to be_empty
    end
  end
end
