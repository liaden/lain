# frozen_string_literal: true

# A lease is where a worker's checkout is known for certain: its origin names
# the path a backend cut. The environment it hands out says so, so whatever
# runs under it can ask the environment rather than guess from a directory.
RSpec.describe Lain::Isolation::Lease do
  let(:env) { Lain::WorkerEnv.new(cwd: "/srv/worktrees/w1", env: { "A" => "1" }) }

  it "hands out an environment naming the checkout its origin names" do
    lease = described_class.new(worker_env: env, origin: described_class::Origin.new(path: "/srv/worktrees/w1"))

    expect(lease.worker_env.checkout).to eq("/srv/worktrees/w1")
    expect(lease.worker_env.cwd).to eq(env.cwd)
    expect(lease.worker_env.env).to eq(env.env)
  end

  it "names no checkout for a lease that cut none" do
    expect(described_class.new(worker_env: env).worker_env.checkout).to be_nil
  end

  # {Isolation::Compose} and {Isolation::DbIndex} rebuild the environment to
  # add their variables, keeping only the origin: the checkout must survive
  # that, which is why the lease says it rather than whoever built the env.
  it "names the checkout through a decorator that rebuilds the environment from scratch" do
    base = described_class.new(worker_env: env, origin: described_class::Origin.new(path: "/srv/worktrees/w1"))
    rebuilt = Lain::WorkerEnv.new(cwd: base.worker_env.cwd, env: base.worker_env.env.merge("DATABASE_URL" => "x"))

    expect(described_class.new(worker_env: rebuilt, origin: base.origin).worker_env.checkout)
      .to eq("/srv/worktrees/w1")
  end
end
