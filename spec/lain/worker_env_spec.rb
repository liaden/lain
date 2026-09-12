# frozen_string_literal: true

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
      expect(Ractor.shareable?(env)).to be(true)
    end

    it "keeps its checkout when its cwd moves" do
      env = described_class.new(cwd: "/srv/w1", env: {}, checkout: "/srv/w1")

      expect(env.with(cwd: "/srv/w1/app").checkout).to eq("/srv/w1")
    end
  end

  # The ONE cwd-resolution rule every exec arm (Exec::Local, Exec::Core) shares
  # -- extracted here so the transports cannot drift apart on it (a panel fix).
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

    # A nil value is the sanctioned scrub marker (mixlib's `ENV[k] = nil` deletes
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

    it "forwards worker_env through the Journaled decorator untouched" do
      injected = described_class.new(cwd: "/sandbox", env: {})
      journaled = Lain::Session::Journaled.new(session: Lain::Session.new(worker_env: injected), journal: [])
      expect(journaled.worker_env).to be(injected)
    end
  end
end
