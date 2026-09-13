# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Lain::Isolation::Null do
  subject(:backend) { described_class.new }

  describe "#acquire" do
    it "leases the shared process WorkerEnv -- the live cwd and env" do
      lease = backend.acquire("worker-1")

      expect(lease.worker_env.cwd).to eq(Dir.pwd)
      expect(lease.worker_env.env).to eq(ENV.to_h)
    end

    it "recomputes the cwd per acquire, so a lease after a chdir names the new dir" do
      Dir.mktmpdir do |dir|
        real = File.realpath(dir)
        Dir.chdir(real) do
          expect(backend.acquire("w").worker_env.cwd).to eq(real)
        end
      end
    end
  end

  # No checkout is cut, so there is no branch to hand back to: the Null base,
  # never a nil a caller must guard.
  it "names no working branch" do
    expect(backend.base).to equal(Lain::Isolation::WorkingBranch::NONE)
  end

  # No checkout is cut, so none is ever kept back on release.
  it "never retains a checkout" do
    expect(backend.retained?("/any/path")).to be(false)
  end

  # No checkout is cut FROM anywhere, so a handback built over `--isolation
  # none` needs the same repository {CLI::IsolationBackend} itself would find
  # -- the one search, never a second walk that could answer a different
  # directory.
  describe "#repo_root" do
    around do |example|
      Dir.mktmpdir("lain-null-repo") do |dir|
        @dir = File.realpath(dir)
        example.run
      end
    end

    let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@dir, "state") }) }

    def build(root) = described_class.new(root:, paths:, home: Dir.home)

    # `root:` has no default -- a `Null.new` with none given has nothing to
    # search from, and every zero-arg call site in `lib/` never asks this
    # question, so there is no cwd-inferring default to fall back on either.
    it "refuses loudly, never nil, when built with no root to search from" do
      expect { described_class.new.repo_root }.to raise_error(Lain::Error, /no root/)
    end

    it "answers the nearest repository at or above the root it was built with" do
      repo = File.join(@dir, "repo")
      FileUtils.mkdir_p(repo)
      FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", repo)
      nested = File.join(repo, "a", "b")
      FileUtils.mkdir_p(nested)

      expect(build(nested).repo_root).to eq(repo)
    end

    it "refuses loudly, never nil, when the search finds no repository" do
      expect { build(@dir).repo_root }.to raise_error(Lain::Error, /git repository/)
    end
  end

  describe "the lease" do
    subject(:lease) { backend.acquire("worker-1") }

    it "is idempotent-loud: first release is observable-true, later releases false" do
      expect(lease.release).to be(true)
      expect(lease.release).to be(false)
      expect(lease.released?).to be(true)
    end
  end
end
