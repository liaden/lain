# frozen_string_literal: true

RSpec.describe Lain::Telemetry::IsolationLease do
  let(:sha) { "a" * 40 }

  it "carries where the checkout is, the commit it was cut from, and the branch" do
    record = described_class.new(kind: :acquired, worker_key: "w-1", backend: "Lain::Isolation::Worktree",
                                 path: "/state/lain/worktrees/abc", base: sha, branch: "feat")

    expect(record.to_journal).to include("type" => "isolation_lease", "path" => "/state/lain/worktrees/abc",
                                         "base" => sha, "branch" => "feat")
  end

  # Absence is the signal, as it is for `service`: a shared-process lease cut
  # no checkout and has no base to name.
  it "leaves them nil for a backend that cuts no checkout" do
    record = described_class.new(kind: :acquired, worker_key: "w-1", backend: "Lain::Isolation::Null")

    expect([record.path, record.base, record.branch]).to eq([nil, nil, nil])
  end

  it "is deeply frozen, even from unfrozen strings" do
    record = described_class.new(kind: :released, worker_key: +"w-1", backend: +"B",
                                 path: +"/state/x", base: +sha, branch: +"feat")

    expect(record).to be_deeply_frozen
  end

  # A researcher's lease outlives its child on purpose, so its end is told
  # apart from a release that gave the checkout back.
  it "records a lease kept rather than released" do
    record = described_class.new(kind: :kept, worker_key: "research.x", backend: "Lain::Isolation::Scratch")

    expect(record.kind).to eq(:kept)
  end

  it "still refuses a kind outside the lease lifecycle" do
    expect { described_class.new(kind: :borrowed, worker_key: "w-1", backend: "B") }
      .to raise_error(ArgumentError, /kind/)
  end

  describe "journal bytes" do
    it "prints every field when all are set" do
      record = described_class.new(kind: :acquired, worker_key: "w-1", backend: "Lain::Isolation::Worktree",
                                   service: "postgres", path: "/state/x", base: "a" * 40, branch: "feat")

      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"isolation_lease","kind":"acquired","worker_key":"w-1","backend":"Lain::Isolation::Worktree",' \
        "\"service\":\"postgres\",\"path\":\"/state/x\",\"base\":\"#{"a" * 40}\",\"branch\":\"feat\"}"
      )
    end

    it "prints null for every optional field" do
      record = described_class.new(kind: :released, worker_key: "w-1", backend: "B")

      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"isolation_lease","kind":"released","worker_key":"w-1","backend":"B","service":null,' \
        '"path":null,"base":null,"branch":null}'
      )
    end
  end

  describe "interning and refusals" do
    def build(**extra)
      described_class.new(kind: :acquired, worker_key: +"w", backend: +"B", path: +"/p", base: +"b", branch: +"br",
                          **extra)
    end

    it "interns path, base and branch across equal records" do
      a = build
      b = build

      expect([a.path.equal?(b.path), a.base.equal?(b.base), a.branch.equal?(b.branch)]).to eq([true] * 3)
    end

    it "interns worker_key and backend across equal records" do
      a = build
      b = build

      expect([a.worker_key.equal?(b.worker_key), a.backend.equal?(b.backend)]).to eq([true, true])
    end

    it "refuses an unknown keyword and a missing worker_key with ArgumentError" do
      expect { build(bogus: 1) }.to raise_error(ArgumentError)
      expect { described_class.new(kind: :acquired, backend: "B") }.to raise_error(ArgumentError)
    end
  end
end
