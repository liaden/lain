# frozen_string_literal: true

require "fileutils"
require "mixlib/shellout"

# Runs the REAL `git` -- the worktree backend genuinely checks out, and git is
# always present, so the default suite exercises it -- while faking every other
# command, so a declared Postgres service provisions deterministically with no
# live server and no docker daemon. Every argv is recorded, which is how a spec
# proves that NO createdb ran at all.
class IsolationBackendShells
  Fake = Struct.new(:argv, :exitstatus, :stderr, :stdout) do
    def run_command = self
  end

  def initialize
    @calls = []
  end

  attr_reader :calls

  def call(*argv, **)
    @calls << argv
    argv.first == "git" ? Mixlib::ShellOut.new(*argv, **) : Fake.new(argv, 0, "", stdout_for(argv))
  end

  private

  # `docker compose port` is the one faked command whose STDOUT is read back
  # ({Isolation::Compose::Stack#published_port} parses it, and refuses on no
  # positive port). Everything else answers empty -- which `ps -q` needs, since
  # a non-empty answer there means the project name is already occupied.
  # argv[6] is the subcommand, after the fixed `docker compose -p X -f Y`.
  def stdout_for(argv) = argv[6] == "port" ? "0.0.0.0:32769\n" : ""
end

# The one seam that turns `--isolation <name>` into a backend object: which
# concrete backend, which decorators over it, and where a worktree's checkouts
# live. Operates on a THROWAWAY repo and a throwaway XDG_RUNTIME_DIR it creates
# itself, never the lain repo it runs in.
RSpec.describe Lain::CLI::IsolationBackend do
  around do |example|
    Dir.mktmpdir("lain-isolation-project") do |project|
      Dir.mktmpdir("lain-isolation-runtime") do |runtime|
        @project = File.realpath(project)
        @runtime = File.realpath(runtime)
        example.run
      end
    end
  end

  let(:shells) { IsolationBackendShells.new }

  # XDG_RUNTIME_DIR points at a throwaway dir, so a leased worktree lands under
  # the tmpdir instead of the machine's real runtime dir.
  let(:paths) { Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => @runtime }) }

  def resolve(name = nil, root: @project, **)
    described_class.resolve(name, root:, paths:, shell_out_factory: shells, **)
  end

  # The spec's own git calls reuse the backend's pinned scrub set, so building
  # the throwaway repo is hermetic under a GIT_*-polluted env (a pre-commit
  # hook) exactly as the backend is.
  def run_git(dir, *args)
    Mixlib::ShellOut.new("git", "-C", dir, *args,
                         environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command.error!
  end

  def init_repo(dir)
    run_git(dir, "init", "-q")
    run_git(dir, "config", "user.email", "test@example.com")
    run_git(dir, "config", "user.name", "Test")
    File.write(File.join(dir, "README"), "seed\n")
    run_git(dir, "add", "README")
    run_git(dir, "commit", "-q", "-m", "seed")
  end

  def declare_services(source, root: @project)
    FileUtils.mkdir_p(File.join(root, ".lain"))
    File.write(File.join(root, ".lain", "services.rb"), source)
  end

  def write_compose_file(root: @project)
    File.write(File.join(root, "compose.yml"), "services: {}\n")
  end

  # The repo's own registrations: one line per worktree, the primary checkout
  # included -- so a stranded lease shows up as a second `worktree ` line.
  def registered_worktrees
    Mixlib::ShellOut.new("git", "-C", @project, "worktree", "list", "--porcelain",
                         environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command.stdout
  end

  def worktree_root = File.join(@runtime, "lain", "worktrees", paths.project_hash(@project))

  describe "the default" do
    it "is the shared-process backend when no isolation option is given" do
      expect(resolve).to be_a(Lain::Isolation::Null)
    end

    it "is what the explicit default name resolves to as well" do
      expect(resolve(described_class::DEFAULT)).to be_a(Lain::Isolation::Null)
    end
  end

  describe "the advertised set" do
    it "resolves every name it advertises, so the help text and the mapping cannot drift" do
      init_repo(@project)

      expect(described_class::BACKENDS.map { |name| resolve(name).class })
        .to eq([Lain::Isolation::Null, Lain::Isolation::Worktree])
    end

    it "refuses an unrecognized name, naming the valid set" do
      expect { resolve("docker") }
        .to raise_error(Lain::Error, /unknown isolation backend "docker".*none.*worktree/m)
    end
  end

  describe "the worktree backend" do
    it "leases under a root derived from the project, not from the cwd it was resolved in" do
      init_repo(@project)
      deep = File.join(@project, "lib", "nested")
      FileUtils.mkdir_p(deep)

      lease = resolve("worktree", root: deep).acquire("worker-1")

      expect(lease.worker_env.cwd).to eq(File.join(worktree_root, paths.project_hash("worker-1")))
    ensure
      lease&.release
    end

    it "refuses by name outside a git repository rather than handing back a backend that fails at acquire" do
      expect { resolve("worktree") }.to raise_error(Lain::Error, /git repository/)
    end
  end

  describe "declared services" do
    it "provisions a declared postgres service over the worktree lease" do
      init_repo(@project)
      declare_services("postgres\n")

      lease = resolve("worktree").acquire("worker-1")

      expect(lease.worker_env.cwd).to start_with(worktree_root)
      expect(lease.worker_env.env).to include("DATABASE_URL")
      expect(shells.calls.map(&:first)).to include("createdb")
    ensure
      lease&.release
    end

    it "reclaims the database and the checkout together on release" do
      init_repo(@project)
      declare_services("postgres\n")
      lease = resolve("worktree").acquire("worker-1")
      cwd = lease.worker_env.cwd

      lease.release

      expect(shells.calls.map(&:first)).to include("dropdb")
      expect(File.directory?(cwd)).to be(false)
    end

    it "adds no service decorator when the project declares no services" do
      init_repo(@project)

      expect(resolve("worktree")).to be_a(Lain::Isolation::Worktree)
    end

    it "runs no provisioning command at all for a lease with no declared services" do
      init_repo(@project)

      lease = resolve("worktree").acquire("worker-1")

      expect(shells.calls.map(&:first).uniq).to eq(%w[git])
      expect(lease.worker_env.env).not_to include("DATABASE_URL")
    ensure
      lease&.release
    end

    # A compose declaration answers no `#provision`; it is the STACK that
    # provisions, one decorator out. Handing the whole collection to the DB
    # provisioner would NoMethodError at acquire, so the partition is asserted
    # structurally here -- the live docker round trip is the :services example.
    it "hands a compose declaration to the compose backend" do
      init_repo(@project)
      write_compose_file
      declare_services(%(compose service: "db", container_port: 5432, env_var: "PG_URL"\n))

      expect(resolve("worktree")).to be_a(Lain::Isolation::Compose)
    end

    # The partition's REACHABLE case: only a project declaring both kinds can
    # tell the two decorators apart, and only an acquire runs the `#provision`
    # that a compose declaration does not answer. Structural assertions cannot
    # catch this -- the naive "hand DbIndex everything" still yields a Compose
    # outermost -- so this example is the one guard the partition has.
    it "provisions a database and a compose stack over one worktree lease" do
      init_repo(@project)
      write_compose_file
      declare_services(<<~SERVICES)
        postgres
        compose service: "db", container_port: 5432, env_var: "COMPOSE_DB_URL"
      SERVICES

      lease = resolve("worktree").acquire("worker-1")

      expect(lease.worker_env.cwd).to start_with(worktree_root)
      expect(lease.worker_env.env).to include("DATABASE_URL", "COMPOSE_DB_URL")
    ensure
      lease&.release
    end
  end

  describe "a compose declaration with no compose file" do
    it "refuses at resolve, naming the files it looked for, rather than at the first acquire" do
      init_repo(@project)
      declare_services(%(compose service: "db", container_port: 5432, env_var: "COMPOSE_DB_URL"\n))

      expect { resolve("worktree") }.to raise_error(Lain::Error, /compose file.*compose\.yaml/m)
    end

    # The resolve-time refusal is a MITIGATION, not a substitute: the file can
    # go missing after resolve, and the backend re-resolves it at acquire. What
    # must never happen either way is a stranded checkout -- release is how a
    # worktree is reclaimed, and one left on disk defeats the next acquire and
    # pollutes `git worktree list`.
    it "strands no checkout when the compose file disappears between resolve and acquire" do
      init_repo(@project)
      write_compose_file
      declare_services(%(compose service: "db", container_port: 5432, env_var: "COMPOSE_DB_URL"\n))
      backend = resolve("worktree")
      FileUtils.rm(File.join(@project, "compose.yml"))

      expect { backend.acquire("worker-1") }.to raise_error(Lain::Isolation::Compose::Refused)
      expect(Dir.glob(File.join(worktree_root, "*"))).to be_empty
      expect(registered_worktrees.lines.grep(/^worktree /).size).to eq(1)
    end
  end

  describe "journalling" do
    it "emits exactly one acquired and one released record per lease" do
      journal = []

      lease = resolve("none", journal:).acquire("worker-1")
      lease.release

      expect(journal.map(&:kind)).to eq(%i[acquired released])
    end

    # The wrap is NEAREST the concrete backend, so the record names the backend
    # that actually isolated the worker rather than the decorator over it -- and
    # a stacked decorator neither double-journals nor breaks the release chain.
    it "wraps once under a service decorator, naming the concrete backend" do
      init_repo(@project)
      declare_services("postgres\n")
      journal = []

      lease = resolve("worktree", journal:).acquire("worker-1")
      lease.release

      expect(journal.map(&:kind)).to eq(%i[acquired released])
      expect(journal.map(&:backend).uniq).to eq(["Lain::Isolation::Worktree"])
    end

    it "journals nothing twice on a double release" do
      journal = []

      lease = resolve("none", journal:).acquire("worker-1")
      2.times { lease.release }

      expect(journal.map(&:kind)).to eq(%i[acquired released])
    end
  end

  # The real thing: a live Postgres stacked over a real git worktree. The default
  # suite fakes createdb/dropdb (see IsolationBackendShells), so this is the only
  # example that proves the resolved stack provisions against a real server.
  # Opt-in via the :services tag (LAIN_SERVICES=1 -- see spec/support/tags.rb).
  describe "end to end", :services do
    # The tools on PATH are not enough: `createdb` installs with the client
    # package and exits nonzero against a server that is not listening, which
    # would report an absent SERVER as a lain regression. A `psql -l` that
    # actually connects is the honest gate.
    before do
      skip("no Postgres server answering -- start one to run this :services spec") \
        unless system("sh", "-c", "psql -l", out: File::NULL, err: File::NULL)
    end

    it "provisions a real per-worker database inside a real leased checkout, then reclaims both" do
      init_repo(@project)
      declare_services("postgres\n")
      backend = described_class.resolve("worktree", root: @project, paths:)
      worker = "itest-#{Process.pid}"

      lease = backend.acquire(worker)
      db = lease.worker_env.env.fetch("DATABASE_URL").split("/").last

      expect(File.directory?(lease.worker_env.cwd)).to be(true)
      expect(system("sh", "-c", "psql -lqt | cut -d'|' -f1 | grep -qw #{db}")).to be(true)

      lease.release
      expect(system("sh", "-c", "psql -lqt | cut -d'|' -f1 | grep -qw #{db}")).to be(false)
      expect(File.directory?(lease.worker_env.cwd)).to be(false)
    end
  end
end
