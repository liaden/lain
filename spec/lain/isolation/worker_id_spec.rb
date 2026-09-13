# frozen_string_literal: true

RSpec.describe Lain::Isolation::WorkerId do
  # The two allocators cannot see each other -- {Lain::Supervisor} numbers the
  # actors an operator ADOPTS, {Lain::Isolation::Leases} numbers the
  # children a model SPAWNS -- so the disjointness of what they mint is this
  # object's property, proved once here rather than assumed at two call sites.
  describe "the two lanes" do
    it "spells an adopted id as the role and its ordinal" do
      expect(described_class.adopted(role: "researcher", ordinal: 3).to_s).to eq("researcher-3")
    end

    it "spells a spawned id so the ordinal is never preceded by a hyphen" do
      spawned = described_class.spawned(role: "researcher", ordinal: 3).to_s

      expect(spawned).to include("researcher")
      expect(spawned).not_to match(/-\d+\z/)
    end

    # The collision the two hand-spelled conventions had: a supervisor role
    # ending in the spawn lane's own infix reproduced a spawned id exactly.
    # `Role::Catalog` is closed, but `Subagent.new(name:)` is public, so the
    # role name is not something this can assume anything about.
    it "cannot be made to collide by a role name that mimics the other lane" do
      adversarial = ["reviewer", "reviewer-spawn", "reviewer-spawn.1", "reviewer-1", "", "a-b-c"]

      adopted = adversarial.flat_map { |role| (1..4).map { |n| described_class.adopted(role:, ordinal: n).to_s } }
      spawned = adversarial.flat_map { |role| (1..4).map { |n| described_class.spawned(role:, ordinal: n).to_s } }

      expect(adopted & spawned).to be_empty
    end

    it "gives every ordinal in one lane a distinct name" do
      minted = (1..50).map { |n| described_class.spawned(role: "researcher", ordinal: n).to_s }

      expect(minted.uniq.size).to eq(50)
    end
  end

  describe "what it refuses" do
    it "refuses a lane outside the closed set" do
      expect { described_class.new(lane: :borrowed, role: "researcher", ordinal: 1) }
        .to raise_error(ArgumentError, /borrowed/)
    end

    it "refuses an ordinal that is not a number" do
      expect { described_class.spawned(role: "researcher", ordinal: "one") }.to raise_error(ArgumentError)
    end

    # An object may not accept the one input that breaks the property it
    # claims: `spawned(role: "r", ordinal: -1)` reads "r-spawn.-1", which is
    # exactly `adopted(role: "r-spawn.", ordinal: 1)`. Unreachable from either
    # allocator -- both count up from zero -- so this closes the claim rather
    # than a live defect.
    it "refuses an ordinal below the first one an allocator can hand out" do
      expect { described_class.spawned(role: "r", ordinal: -1) }.to raise_error(ArgumentError, /ordinal/)
      expect { described_class.adopted(role: "r", ordinal: 0) }.to raise_error(ArgumentError, /ordinal/)
    end
  end

  # A value, so two mints of the same worker are the same worker.
  # A caller-named worker id becomes a ref under refs/lain/worker/, so it is
  # judged by git itself and refused, never escaped: the name an operator
  # reads is the name on the ref.
  describe ".checked, a worker name its caller hands in" do
    it "answers a name git would put in a worker ref" do
      expect(described_class.checked("issue.demo.a")).to eq("issue.demo.a")
    end

    it "refuses a name git would not accept in a ref" do
      ["bad name", "a..b", "x.lock", "", "x~1", ".hidden"].each do |name|
        expect { described_class.checked(name) }.to raise_error(described_class::Refused, /cannot name a ref/)
      end
    end
  end

  it "equates two ids minted from the same lane, role and ordinal" do
    expect(described_class.spawned(role: "researcher", ordinal: 1))
      .to eq(described_class.spawned(role: "researcher", ordinal: 1))
  end
end
