# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Epic::Reopen do
  let(:io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io:) }
  let(:current) { { "a" => "blake3:new" } }
  let(:digests) do
    instance_double(Lain::CLI::EpicSubmit::Digests).tap do |double|
      allow(double).to receive(:digest) { |_slug, _stage, id| current[id] }
    end
  end
  let(:records) { [] }
  let(:reopen) { described_class.new(journals: -> { records }, digests:, journal:) }

  def decided(digest, verdict: Lain::Approval::Verdict::Approve.new, policy: "signoff")
    Lain::Epic::GateDecision.new(artifact_digest: digest, epic_slug: "alpha", stage: "issue_plan", verdict:,
                                 answered_by: "human", policy:, latency: 0.1, issue_id: "a").to_journal
  end

  def reopened = reopen.reopened(epic_slug: "alpha", issue_id: "a")

  context "when the issue's plan stands approved at other bytes" do
    let(:records) { [decided("blake3:old")] }

    it "journals a deferred denial at the new digest, saying an edit reopened it" do
      reopened

      expect(journal_records(io, "gate_decision")).to contain_exactly(
        a_hash_including("artifact_digest" => "blake3:new", "epic_slug" => "alpha", "stage" => "issue_plan",
                         "issue_id" => "a", "policy" => "deferred", "verdict" => "deferred",
                         "reason" => "reopened by an edit", "answered_by" => "epic_write")
      )
    end

    it "journals the wait beside it, as a deferral does" do
      reopened

      expect(journal_records(io, "awaiting_human")).to contain_exactly(
        a_hash_including("kind" => "gate", "ref" => "blake3:new", "deferred" => true, "epic_slug" => "alpha",
                         "stage" => "issue_plan", "issue_id" => "a")
      )
    end

    it "names the issue it reopened" do
      expect(reopened).to eq(["a"])
    end

    it "leaves the folded queue holding the new digest parked and the old approval undisturbed" do
      reopened
      queue = Lain::Epic::SignoffQueue.from_journal(records + journal_records(io, "gate_decision"))

      expect(queue.parked("alpha", "issue_plan", issue_id: "a").map(&:artifact_digest)).to eq(["blake3:new"])
      expect(queue.standing?("blake3:old", "alpha", "issue_plan", issue_id: "a")).to be(true)
    end

    it "writes nothing a second time over the same bytes" do
      reopened
      records.push(*journal_records(io, "gate_decision"))

      expect { reopened }.not_to change(io, :string)
    end
  end

  context "when an edit is reverted to the approved bytes" do
    let(:records) { [decided("blake3:old")] }
    let(:current) { { "a" => "blake3:old" } }

    def parked_at(digest)
      records.push(decided(digest, verdict: Lain::Epic::GateDecision::Deferred.new, policy: "deferred"))
    end

    it "drains the item the edit parked and leaves the approval standing" do
      parked_at("blake3:new")

      expect(reopened).to eq([])
      queue = Lain::Epic::SignoffQueue.from_journal(records + journal_records(io, "gate_decision"))
      expect(queue.parked("alpha", "issue_plan", issue_id: "a")).to be_empty
      expect(queue.approved?("alpha", "issue_plan", issue_id: "a")).to be(true)
      expect(queue.standing?("blake3:old", "alpha", "issue_plan", issue_id: "a")).to be(true)
    end

    it "writes nothing when nothing is parked" do
      expect([reopened, io.string]).to eq([[], ""])
    end
  end

  context "when the bytes are the ones approved" do
    let(:records) { [decided("blake3:new")] }

    it "writes nothing and reopens nothing" do
      expect([reopened, io.string]).to eq([[], ""])
    end
  end

  context "when the issue was never approved" do
    it "writes nothing" do
      expect([reopened, io.string]).to eq([[], ""])
    end
  end

  context "when a denial is what stands" do
    let(:records) { [decided("blake3:old", verdict: Lain::Approval::Verdict::Deny.new)] }

    it "writes nothing" do
      expect([reopened, io.string]).to eq([[], ""])
    end
  end

  context "when the plan no longer reads" do
    let(:records) { [decided("blake3:old")] }
    let(:current) { {} }

    it "writes nothing" do
      expect([reopened, io.string]).to eq([[], ""])
    end
  end

  describe ".stale" do
    it "lists the issues whose approval stands over other bytes than they hold now" do
      queue = Lain::Epic::SignoffQueue.from_journal([decided("blake3:old")])
      source = instance_double(Lain::CLI::EpicSubmit::Digests)
      allow(source).to receive(:digest) { |_slug, _stage, id| { "a" => "blake3:new" }[id] }

      expect(described_class.stale(queue, source, epic_slug: "alpha", issue_ids: %w[a b])).to eq(["a"])
    end
  end
end
