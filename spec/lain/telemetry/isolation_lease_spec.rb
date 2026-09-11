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

  it "still refuses a kind outside the lease lifecycle" do
    expect { described_class.new(kind: :borrowed, worker_key: "w-1", backend: "B") }
      .to raise_error(ArgumentError, /kind/)
  end
end
