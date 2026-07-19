# frozen_string_literal: true

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

  describe "the lease" do
    subject(:lease) { backend.acquire("worker-1") }

    it "releases as a no-op that does not raise" do
      expect { lease.release }.not_to raise_error
    end

    it "is idempotent-loud: first release is observable-true, later releases false" do
      expect(lease.release).to be(true)
      expect(lease.release).to be(false)
      expect(lease.released?).to be(true)
    end
  end
end
