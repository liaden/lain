# frozen_string_literal: true

# The dual-ledger arm's Task/Progress structure -- Magentic-One's two halves as
# one deeply frozen value. NOT Lain::Ledger (the cost ledger); these specs pin
# the immutability the sent-not-stored carrier depends on, the stable rendered
# projection, and the signature the stall detector reads.
RSpec.describe Lain::Arm::LedgerState do
  subject(:ledger) { described_class.initial(task: "summarize the paper") }

  describe "the seed ledger" do
    it "makes the task the first fact and chooses no subtask yet" do
      expect(ledger.facts).to eq(["Task: summarize the paper"])
      expect(ledger.plan).to be_empty
      expect(ledger.progress).to be_empty
      expect(ledger.next_subtask).to be_nil
    end
  end

  describe "immutability -- the sent-not-stored carrier never mutates" do
    it "is Ractor.shareable? (deeply frozen, no reachable mutable state)" do
      expect(ledger.advanced(note: "read section 1", next_subtask: "read section 2"))
        .to be_ractor_shareable
    end

    it "is value-equal to another state built from the same inputs" do
      expect(described_class.initial(task: "x")).to eq(described_class.initial(task: "x"))
    end

    it "returns a NEW value from #advanced rather than mutating" do
      advanced = ledger.advanced(note: "did a thing", next_subtask: "next")

      expect(ledger.progress).to be_empty # original untouched
      expect(advanced.progress).to eq(["did a thing"])
      expect(advanced.next_subtask).to eq("next")
    end

    it "keeps facts and progress across a replan, installing a fresh plan" do
      worked = ledger.advanced(note: "found data", next_subtask: "stuck here")
      replanned = worked.replanned(plan: ["try another angle"], next_subtask: "new angle")

      expect(replanned.facts).to eq(worked.facts)
      expect(replanned.progress).to eq(["found data"]) # work done survives
      expect(replanned.plan).to eq(["try another angle"])
      expect(replanned.next_subtask).to eq("new angle")
    end
  end

  describe "#to_reminder -- the Workspace projection" do
    it "renders every section even when empty, so the shape is stable" do
      reminder = ledger.to_reminder

      expect(reminder).to include("Facts: Task: summarize the paper")
      expect(reminder).to include("Plan: (none)")
      expect(reminder).to include("Progress: (none)")
      expect(reminder).to include("Next subtask: (none chosen)")
    end

    it "names the pending subtask once one is chosen" do
      expect(ledger.advanced(note: "step", next_subtask: "do the next bit").to_reminder)
        .to include("Next subtask: do the next bit")
    end
  end

  describe "#signature -- the stall detector's input" do
    it "is unchanged when no progress is made (same count, same subtask)" do
      a = ledger.advanced(note: "one", next_subtask: "stuck")
      b = a # a step that recorded nothing new hands the same ledger back

      expect(b.signature).to eq(a.signature)
    end

    it "changes when progress grows" do
      before = ledger.advanced(note: "one", next_subtask: "stuck")
      after = before.advanced(note: "two", next_subtask: "stuck")

      expect(after.signature).not_to eq(before.signature)
    end

    it "changes on a replan even though progress did not grow" do
      stuck = ledger.advanced(note: "one", next_subtask: "stuck")
      replanned = stuck.replanned(plan: ["new"], next_subtask: "fresh")

      expect(replanned.signature).not_to eq(stuck.signature)
    end
  end
end
