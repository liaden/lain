# frozen_string_literal: true

require "stringio"

# A fake backend duck -- deliberately NOT {Lain::Isolation::Null} or
# {Lain::Isolation::Worktree} -- proving the decorator works over the generic
# `acquire(worker_id) -> Lease` seam any backend answers, not a concrete one.
class FakeIsolationBackend
  Lease = Lain::Isolation::Lease

  def initialize
    @acquired = []
  end

  attr_reader :acquired

  def base = :the_working_branch

  def retained?(path) = path == "/fake/retained"

  def repo_root = "/fake/repo"

  def acquire(worker_id)
    @acquired << worker_id
    Lease.new(worker_env: Lain::WorkerEnv.new(cwd: "/fake/#{worker_id}", env: {}))
  end
end

RSpec.describe Lain::Isolation::Journal do
  let(:backend) { FakeIsolationBackend.new }
  let(:io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io:) }
  let(:decorator) { described_class.new(backend:, journal:) }

  def parsed_records
    io.string.each_line.map { |line| Lain::Journal.parse(line) }
  end

  # A handback reads its target off the fleet's isolation, and this decorator
  # sits between that caller and the backend that knows it.
  it "answers the wrapped backend's working branch" do
    expect(decorator.base).to eq(:the_working_branch)
  end

  # A handback record says whether release kept a dirty checkout, and only the
  # backend that released it knows.
  it "answers whether the wrapped backend retained a checkout on release" do
    expect([decorator.retained?("/fake/retained"), decorator.retained?("/fake/other")]).to eq([true, false])
  end

  # A handback merges into the repository the backend cut its checkouts from,
  # and only the backend that cut them knows which one that is.
  it "answers the wrapped backend's repository" do
    expect(decorator.repo_root).to eq("/fake/repo")
  end

  describe "#acquire" do
    it "forwards the worker_id to the wrapped backend" do
      decorator.acquire("worker-1")

      expect(backend.acquired).to eq(["worker-1"])
    end

    it "returns a lease whose WorkerEnv is the backend's own" do
      lease = decorator.acquire("worker-1")

      expect(lease.worker_env.cwd).to eq("/fake/worker-1")
    end

    it "emits an attributed isolation_lease record naming the worker key" do
      decorator.acquire("worker-1")

      expect(io).to include_journal_record("isolation_lease", kind: "acquired", worker_key: "worker-1",
                                                              backend: "FakeIsolationBackend")
    end

    it "stringifies a non-String worker_id into the worker_key" do
      decorator.acquire(42)

      expect(io).to include_journal_record("isolation_lease", kind: "acquired", worker_key: "42")
    end
  end

  describe "the returned lease's #release" do
    subject(:lease) { decorator.acquire("worker-1") }

    it "emits an attributed isolation_lease release record naming the worker key" do
      lease.release

      expect(io).to include_journal_record("isolation_lease", kind: "released", worker_key: "worker-1",
                                                              backend: "FakeIsolationBackend")
    end

    it "journals the acquire before the release, in lifecycle order" do
      lease.release

      types = parsed_records.map { |record| record.fetch("type") }
      expect(types).to eq(%w[isolation_lease isolation_lease])
      kinds = parsed_records.map { |record| record.fetch("kind") }
      expect(kinds).to eq(%w[acquired released])
    end

    it "is idempotent-loud, matching Lease's own contract" do
      expect(lease.release).to be(true)
      expect(lease.release).to be(false)
    end

    it "journals a release only once, even when released twice" do
      lease.release
      lease.release

      released = parsed_records.select { |record| record["kind"] == "released" }
      expect(released.size).to eq(1)
    end

    # path/base/branch are attribution a reaper reads back -- where the
    # checkout is and what it was cut from -- never the env or its credentials.
    it "carries no worker_env/credential fields onto the record" do
      lease.release

      expect(parsed_records.map(&:keys))
        .to all(match_array(%w[ts type kind worker_key backend service path base branch]))
    end
  end
end
