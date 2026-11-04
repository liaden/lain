# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::WorkerEnv do
  describe ".default" do
    it "carries the live process working directory" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          expect(described_class.default.cwd).to eq(Dir.pwd)
        end
      end
    end

    it "snapshots the process environment" do
      expect(described_class.default.env).to eq(ENV.to_h)
    end

    it "reads the current directory fresh on each call, not once at load" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          expect(described_class.default.cwd).to eq(File.realpath(dir))
        end
      end
    end
  end

  # Where a leased worker's work lands, said by the lease rather than guessed
  # from the filesystem: a guard holds a child's writes at the checkout its
  # lease cut, and at nothing a directory merely looks like.
  describe "#checkout" do
    it "names no checkout for the host's own environment" do
      expect(described_class.default.checkout).to be_nil
    end

    it "carries the checkout root it was given, and stays shareable" do
      env = described_class.new(cwd: "/srv/w1/app", env: {}, checkout: +"/srv/w1")

      expect(env.checkout).to eq("/srv/w1")
      expect(env).to be_deeply_frozen
    end

    it "keeps its checkout when its cwd moves" do
      env = described_class.new(cwd: "/srv/w1", env: {}, checkout: "/srv/w1")

      expect(env.with(cwd: "/srv/w1/app").checkout).to eq("/srv/w1")
    end
  end

  # What the agent working in this environment may read, write and run, so
  # every layer judging its calls asks one value.
  describe "#bounds" do
    let(:bounds) { Lain::Sensitivity::Bounds.of(reads: ["/srv"], writes: ["/srv/w1"]) }

    it "carries no bounds until an agent's are cut for it" do
      expect(described_class.default.bounds).to be_nil
    end

    it "carries the bounds cut for it, and stays shareable" do
      Dir.mktmpdir("lain-worker-env-bounds") do |dir|
        root = File.join(File.realpath(dir), "project").tap { FileUtils.mkdir_p(_1) }
        lease = File.join(File.realpath(dir), "children", "w1").tap { FileUtils.mkdir_p(_1) }
        policy = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: dir, cwd: root, root:),
                                               root:, read_roots: [dir])
        leased = described_class.new(cwd: lease, env: { "A" => "1" }, checkout: lease)
        cut = Lain::Sensitivity::Policy.bounds_for(policy, leased)
        env = leased.with(bounds: cut)

        expect(env.bounds).to eq(cut)
        expect(env).to be_deeply_frozen
      end
    end

    it "keeps its bounds when its cwd moves" do
      env = described_class.new(cwd: "/srv/w1", env: {}, bounds:)

      expect(env.with(cwd: "/srv/w1/app").bounds).to eq(bounds)
    end
  end

  # The ONE cwd-resolution rule every exec arm (Exec::Local, Exec::Docker) shares
  # -- extracted here so the arms cannot drift apart on it (a panel fix).
  describe "#resolve" do
    subject(:worker_env) { described_class.new(cwd: "/work", env: {}) }

    it "resolves a relative path under its cwd, honors an absolute one, defaults to its cwd" do
      expect(worker_env.resolve("sub/dir")).to eq("/work/sub/dir")
      expect(worker_env.resolve("/abs")).to eq("/abs")
      expect(worker_env.resolve(nil)).to eq("/work")
    end
  end

  describe "as a deeply frozen value object" do
    subject(:worker_env) { described_class.new(cwd: "/work", env: { "A" => "1" }) }

    it "is Ractor.shareable? -- no reachable mutable state" do
      expect(worker_env).to be_deeply_frozen
    end

    it "freezes its cwd string" do
      expect(worker_env.cwd).to be_frozen
    end

    it "freezes its env hash and the strings inside it" do
      expect(worker_env.env).to be_frozen
      expect(worker_env.env.keys).to all(be_frozen)
      expect(worker_env.env.values).to all(be_frozen)
    end

    it "does not alias a mutation of the caller's env hash back into itself" do
      source = { "A" => "1" }
      built = described_class.new(cwd: "/work", env: source)
      expect(built.env).to eq("A" => "1")
    end

    # A nil value is the sanctioned scrub marker (a nil value deletes the variable
    # in the child). The key must be RETAINED with its nil, not dropped, and the
    # value object must stay shareable -- nil is frozen.
    it "preserves a nil env value (the scrub marker) rather than dropping the key" do
      worker_env = described_class.new(cwd: "/work", env: { "SCRUB" => nil, "KEEP" => "v" })
      expect(worker_env.env).to eq("SCRUB" => nil, "KEEP" => "v")
      expect(worker_env).to be_deeply_frozen
    end
  end

  describe "on the Session that lends it to tools" do
    it "defaults a real Session to WorkerEnv.default" do
      expect(Lain::Session.new.worker_env.cwd).to eq(Dir.pwd)
    end

    it "carries an injected WorkerEnv unchanged" do
      injected = described_class.new(cwd: "/sandbox", env: { "DATABASE_URL" => "postgres://x" })
      expect(Lain::Session.new(worker_env: injected).worker_env).to be(injected)
    end

    it "answers the default from Session::Null (the context-less path)" do
      expect(Lain::Session::Null.instance.worker_env.cwd).to eq(Dir.pwd)
    end

    it "holds the injected worker_env untouched on a session that journals" do
      injected = described_class.new(cwd: "/sandbox", env: {})
      journaled = Lain::Session.new(worker_env: injected, journal: [])
      expect(journaled.worker_env).to be(injected)
    end
  end
end
