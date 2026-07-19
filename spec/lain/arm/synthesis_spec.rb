# frozen_string_literal: true

# The synthesis pass folds N worker outcomes into ONE turn that writes the
# first multi-parent causal Event in the repo: the fold turn's `causal_parents`
# name the worker result turns it folded (event.rb:37). These specs pin the
# fold's three loud contracts -- it names every committed worker head, it keeps
# a failed worker as a NAMED input rather than dropping it, and it re-attributes
# worker spend onto the reachable fold turn so a Run over it never undercounts.
RSpec.describe Lain::Arm::Synthesis do
  subject(:synthesis) { described_class.new }

  let(:store) { Lain::Store.new }
  let(:lead) do
    Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "orchestrate" }])
  end

  # A worker's final Timeline, committed into the SHARED store so its head is a
  # valid causal parent (referential integrity holds only for heads the Store saw).
  def worker(text)
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "do #{text}" }])
                  .commit(role: :assistant, content: [{ "type" => "text", "text" => text }])
  end

  def usage_record(digest, tokens)
    { "type" => "turn_usage", "digest" => digest, "model" => "claude-sonnet-4",
      "stop_reason" => "end_turn", "usage" => { "input_tokens" => tokens, "output_tokens" => 0 } }
  end

  def ok_result(timeline, tokens)
    Lain::Arm::Synthesis::Result.ok(
      head_digest: timeline.head_digest, text: timeline.head.content.first["text"],
      usage_records: [usage_record(timeline.head_digest, tokens)]
    )
  end

  describe "#fold — one multi-parent turn over the workers" do
    it "commits an assistant turn naming every committed worker head as a causal parent" do
      wa = worker("A")
      wb = worker("B")

      folded = synthesis.fold(lead, [ok_result(wa, 10), ok_result(wb, 10)])

      expect(folded.timeline.head.role).to eq("assistant")
      expect(folded.timeline.head.render_parent).to eq(lead.head_digest)
      expect(folded.timeline.head.causal_parents).to contain_exactly(wa.head_digest, wb.head_digest)
    end

    it "folds each worker's text into the synthesized content" do
      folded = synthesis.fold(lead, [ok_result(worker("alpha"), 10), ok_result(worker("beta"), 10)])

      expect(folded.timeline.head.content.first["text"]).to include("alpha").and include("beta")
    end
  end

  # Escalation trigger: a failed worker is a NAMED input, not an omission.
  describe "a failed worker survives the fold" do
    it "keeps the error in the synthesized content" do
      failed = Lain::Arm::Synthesis::Result.failed(error: "kaboom")

      folded = synthesis.fold(lead, [ok_result(worker("A"), 10), failed])

      expect(folded.timeline.head.content.first["text"]).to include("kaboom")
    end

    it "does not forge a causal edge for a worker that committed no turn" do
      wa = worker("A")

      folded = synthesis.fold(lead, [ok_result(wa, 10), Lain::Arm::Synthesis::Result.failed(error: "x")])

      expect(folded.timeline.head.causal_parents).to contain_exactly(wa.head_digest)
    end
  end

  # Escalation trigger: a dangling causal parent must fail LOUD, not be dropped.
  describe "a dangling worker head fails loud" do
    it "raises rather than committing a synthesis event naming a head the Store never saw" do
      dangling = Lain::Arm::Synthesis::Result.ok(
        head_digest: "blake3:#{"0" * 64}", text: "ghost", usage_records: []
      )

      expect { synthesis.fold(lead, [dangling]) }.to raise_error(Lain::Store::MissingObject)
    end
  end

  # The reachability contract, at the fold's grain: a fresh-root worker's turns
  # are NOT on the render ancestry the Ledger walks, so the fold re-attributes
  # every worker's spend onto the reachable synthesis turn (the decider_sweep
  # accounting pattern). The join must land on the fold turn, but the record must
  # stay HONEST about it -- a bare re-key would assert the no-model-call synthesis
  # turn incurred N native payments, blinding an auditor.
  describe "pricing reaches every worker's spend" do
    it "re-keys worker usage onto the reachable fold turn so the total never undercounts" do
      folded = synthesis.fold(lead, [ok_result(worker("A"), 30), ok_result(worker("B"), 70)])
      ledger = Lain::Ledger.from_journal(folded.ledger_entries)

      expect(ledger.usage(folded.timeline).total_tokens).to eq(100)
      expect(folded.ledger_entries.map { |record| record["digest"] }.uniq).to eq([folded.timeline.head_digest])
    end

    it "preserves each worker payment's own model so per-worker cost still prices" do
      folded = synthesis.fold(lead, [ok_result(worker("A"), 30), ok_result(worker("B"), 70)])

      expect(folded.ledger_entries.map { |record| record["model"] }).to all(eq("claude-sonnet-4"))
    end

    # Journal honesty (panel BLOCKER / probe 3): a replayed journal must let an
    # auditor tell re-attributed usage apart from native, and recover which worker
    # spent what -- every moved record is marked and names the worker head it came
    # from.
    it "labels each re-attributed record so an auditor can tell it from native usage" do
      folded = synthesis.fold(lead, [ok_result(worker("A"), 30), ok_result(worker("B"), 70)])

      synth = folded.timeline.head_digest
      expect(folded.ledger_entries).to all(include("reattributed" => true))
      expect(folded.ledger_entries.none? { |record| record["attributed_from"] == synth }).to be(true)
    end

    it "lets an auditor recover per-worker spend from the re-attributed records" do
      wa = worker("A")
      wb = worker("B")
      folded = synthesis.fold(lead, [ok_result(wa, 30), ok_result(wb, 70)])

      per_worker = folded.ledger_entries
                         .group_by { |record| record["attributed_from"] }
                         .transform_values { |records| records.sum { |record| record.dig("usage", "input_tokens") } }

      expect(per_worker).to eq(wa.head_digest => 30, wb.head_digest => 70)
    end
  end
end
