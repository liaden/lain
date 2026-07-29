# frozen_string_literal: true

require "json"
require "tmpdir"

# T13: `lain epic queue` -- the surface a human drains the sign-off queue
# through. The queue is a FOLD over journaled `gate_decision` records, so
# draining is journaling and nothing mutates: `approve`/`deny` append a terminal
# decision and the next fold sees the partition drained.
#
# The rule this file exists to pin: a failed rebuild ABORTS. It never degrades
# to an empty queue, because this is the screen a human reads specifically to
# decide that nothing is outstanding.
RSpec.describe Lain::CLI::EpicQueue do
  subject(:queue) { described_class.new(paths:, clock:) }

  around do |example|
    Dir.mktmpdir { |dir| @state_home = dir and example.run }
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state_home }) }

  # Frozen "now", so age and the journaled latency are functions of the fixture
  # rather than of when the suite ran.
  let(:now) { Time.utc(2026, 7, 28, 9, 0, 0) }
  let(:clock) { -> { now } }
  # Shaped like a real content address ({Canonical.digest}'s "blake3:<64 hex>"),
  # so the rendering is exercised at the width a human actually copies from.
  let(:digest_a) { "blake3:#{"a" * 64}" }
  let(:digest_b) { "blake3:#{"b" * 64}" }
  let(:digest_c) { "blake3:#{"c" * 64}" }
  let(:evidence_a) { "blake3:#{"1" * 64}" }

  # Built through the real producers, so the fixture cannot drift from the wire
  # shape T5 and T7 actually write (the sessions_spec `header` idiom).
  def decision(digest:, at:, policy:, approved: false, slug: "alpha", stage: "research",
               answered_by: "gate_adjudicator", evidence_digest: nil, reason: nil)
    Lain::Approval::GateDecision.new(artifact_digest: digest, epic_slug: slug, stage:, approved:,
                                     answered_by:, policy:, latency: 1.5, evidence_digest:, reason:)
                                .to_journal.merge("ts" => at)
  end

  def evidence(digest:, at:, question:, slug: "alpha", stage: "research", text: "the spike found two answers")
    gated = { artifact_digest: digest, epic_slug: slug, stage:, question: }
    Lain::Approval::Gate::Adjudicator::GateEvidence.gathered(text, gated, latency: 2.0)
                                                   .to_journal.merge("ts" => at)
  end

  # A String goes down verbatim, so a fixture can write a genuinely damaged line
  # (truncated, or never JSON at all) rather than a JSON-encoded String.
  def write_journal(name, records)
    lines = records.map { |record| record.is_a?(String) ? record : JSON.generate(record) }
    path = File.join(paths.sessions_dir, name)
    File.write(path, "#{lines.join("\n")}\n")
    path
  end

  def journal_records
    Dir.children(paths.sessions_dir).select { |name| name.end_with?(".ndjson") }.sort
       .flat_map { |name| Lain::Journal.records(File.foreach(File.join(paths.sessions_dir, name))).to_a }
  end

  def gate_decisions = journal_records.select { |record| record["type"] == "gate_decision" }

  def refolded = Lain::Approval::SignoffQueue.from_journal(journal_records)

  # Scenario: approving a parked item drains it
  describe "#approve" do
    before do
      write_journal("20260728T060000-100.ndjson",
                    [decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred", evidence_digest: evidence_a)])
    end

    it "drains the partition when the queue refolds over all journals" do
      expect(refolded.drained?("alpha", "research")).to be(false)

      queue.approve(digest_a)

      expect(refolded.drained?("alpha", "research")).to be(true)
    end

    it "journals a terminal decision answered by the human under the signoff policy" do
      queue.approve(digest_a)

      terminal = gate_decisions.find { |record| record["policy"] == "signoff" }
      expect(terminal).to include("artifact_digest" => digest_a, "epic_slug" => "alpha", "stage" => "research",
                                  "approved" => true, "answered_by" => "human", "policy" => "signoff")
    end

    it "carries the evidence the verdict was reached on into the terminal record" do
      queue.approve(digest_a)

      terminal = gate_decisions.find { |record| record["policy"] == "signoff" }
      expect(terminal["evidence_digest"]).to eq(evidence_a)
    end

    # Not "never zero": a sign-off in the same microsecond as the deferral is
    # legitimately 0.0. What is refused is an UNMEASURED zero -- see the
    # unreadable-ts and future-ts examples below.
    it "measures latency as the wait from park to sign-off" do
      queue.approve(digest_a)

      terminal = gate_decisions.find { |record| record["policy"] == "signoff" }
      expect(terminal["latency"]).to eq(3 * 60 * 60.0)
    end

    it "names the artifact and the partition it signed off" do
      expect(queue.approve(digest_a)).to include(digest_a, "alpha", "research")
    end

    # Scenario: an unknown digest is loud and helpful
    it "refuses an unknown digest, naming it and listing the parked ones" do
      expect { queue.approve(digest_c) }
        .to raise_error(described_class::UnknownDigest, /#{Regexp.escape(digest_c)}.*#{Regexp.escape(digest_a)}/m)
    end

    it "journals nothing at all when the digest is unknown" do
      expect { queue.approve(digest_c) }.to raise_error(described_class::UnknownDigest)

      expect(gate_decisions.map { |record| record["policy"] }).to eq(["deferred"])
    end
  end

  describe "#deny" do
    before do
      write_journal("20260728T060000-100.ndjson",
                    [decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred")])
    end

    it "drains the partition, because a refused artifact awaits nobody's sign-off" do
      queue.deny(digest_a)

      expect(refolded.drained?("alpha", "research")).to be(true)
    end

    it "journals a human signoff decision that did not approve" do
      queue.deny(digest_a)

      terminal = gate_decisions.find { |record| record["policy"] == "signoff" }
      expect(terminal).to include("approved" => false, "answered_by" => "human", "policy" => "signoff")
    end

    it "records the human's rationale when one is given" do
      queue.deny(digest_a, reason: "the backfill is unbounded")

      terminal = gate_decisions.find { |record| record["policy"] == "signoff" }
      expect(terminal["reason"]).to eq("the backfill is unbounded")
    end
  end

  # Scenario: the listing leads with what needs the human
  describe "#listing" do
    before do
      # A sits at the LATER stage and B at the earlier one, deliberately: stage
      # order alone would then lead with B, so "A first" can only be the
      # reviewable-first rule and not the pipeline one riding along.
      parked_with_evidence = [
        decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "deferred",
                 answered_by: "deferred", stage: "epic_plan", evidence_digest: evidence_a,
                 reason: "the spike found two answers"),
        evidence(digest: digest_a, at: "2026-07-28T06:00:01.000000Z", stage: "epic_plan",
                 question: "Does the schema migration need a backfill?")
      ]
      # Parked with no evidence gathered -- nothing for a human to read yet.
      parked_bare = decision(digest: digest_b, at: "2026-07-28T07:00:00.000000Z", policy: "deferred",
                             answered_by: "deferred")
      already_terminal = [
        decision(digest: digest_c, at: "2026-07-28T07:30:00.000000Z", policy: "deferred",
                 answered_by: "deferred"),
        decision(digest: digest_c, at: "2026-07-28T07:40:00.000000Z", policy: "signoff",
                 approved: true, answered_by: "human")
      ]
      write_journal("20260728T060000-100.ndjson", [*parked_with_evidence, parked_bare, *already_terminal])
    end

    it "renders exactly the two parked items and never the terminal one" do
      rendered = queue.listing

      expect(rendered).to include(digest_a, digest_b)
      expect(rendered).not_to include(digest_c)
    end

    it "shows each item's stage, question, and evidence digest" do
      rendered = queue.listing

      expect(rendered).to include("research", "Does the schema migration need a backfill?", evidence_a)
      expect(rendered).to include("epic_plan")
    end

    it "leads with the item that has evidence to review" do
      rendered = queue.listing

      expect(rendered.index(digest_a)).to be < rendered.index(digest_b)
    end

    # Among items that CAN be reviewed, the earlier stage goes first: its
    # partition is the one blocking the later stages ({Epic::Stage}'s boundary
    # rule), so draining it unblocks the most work.
    it "orders reviewable items by pipeline stage" do
      write_journal("20260728T061000-101.ndjson",
                    [decision(digest: digest_c, at: "2026-07-28T08:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred", evidence_digest: evidence_a)])
      rendered = queue.listing

      expect(rendered.index(digest_c)).to be < rendered.index(digest_a)
    end

    it "shows how long each item has been waiting" do
      expect(queue.listing).to include("3h")
    end

    it "says so loudly when a question cannot be recovered from the journal" do
      expect(queue.listing).to include("not recoverable")
    end

    it "narrows to one epic when a slug is given" do
      write_journal("20260728T061000-101.ndjson",
                    [decision(digest: digest_c, at: "2026-07-28T06:10:00.000000Z", policy: "deferred",
                              answered_by: "deferred", slug: "beta")])

      expect(queue.listing("beta")).to include(digest_c)
      expect(queue.listing("beta")).not_to include(digest_a)
    end

    # Guarded against passing vacuously: an implementation returning "" every
    # time is also "deterministic", so the rendering must be shown non-trivial
    # before its stability means anything.
    it "is deterministic" do
      first = queue.listing

      expect(first).to include(digest_a, digest_b)
      expect(described_class.new(paths:, clock:).listing).to eq(first)
    end
  end

  describe "an empty queue" do
    it "names the directory it folded, so 'nothing outstanding' is checkable" do
      expect(queue.listing).to include(paths.sessions_dir)
    end

    it "reports what it understood, not merely how many files it opened" do
      write_journal("20260728T060000-100.ndjson",
                    [decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "signoff",
                              approved: true, answered_by: "human")])

      expect(queue.listing).to match(/1 line.*1 gate record/m)
    end
  end

  # THE BLOCKER: "folded 1 journal" counts FILES. A directory holding one file
  # of garbage, or one truncated mid-record, rendered a clean all-clear -- and a
  # lost deferral reads as drained. This is the one screen whose entire job is
  # to justify the sentence "nothing is outstanding".
  describe "a journal the fold could read but not understand" do
    it "does not render a clean all-clear over lines it could not parse" do
      write_journal("20260728T060000-100.ndjson", ["}{ not a record at all", "still not a record"])

      expect(queue.listing).to include("2 lines could not be parsed")
    end

    it "says plainly that the emptiness is unproven" do
      write_journal("20260728T060000-100.ndjson", ["}{ truncated mid-rec"])

      expect(queue.listing).to include("not proven")
    end

    it "warns on a NON-empty listing too, where a missing deferral hides just as well" do
      write_journal("20260728T060000-100.ndjson",
                    [decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred"),
                     "}{ truncated mid-rec"])

      expect(queue.listing).to include(digest_a).and include("1 line could not be parsed")
    end

    # A Rust tracing span sharing the fd is valid JSON and simply is not ours.
    # Warning about it would cry wolf on every session that shared its journal.
    it "stays quiet about a foreign JSON record" do
      write_journal("20260728T060000-100.ndjson",
                    [{ "ts" => "2026-07-28T06:00:00.000000Z", "level" => "INFO", "target" => "lain_core" }])

      expect(queue.listing).not_to include("could not be parsed")
    end
  end

  # SHOULD-FIX 3: the same bytes can be gated at two stages, so one digest can
  # be parked twice. Signing off "the digest" signs off each place it waits, and
  # the confirmation names them -- leaving one parked with no sign to say so is
  # exactly the failure this surface exists to prevent.
  describe "a digest parked in two partitions" do
    before do
      write_journal("20260728T060000-100.ndjson",
                    [decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred"),
                     decision(digest: digest_a, at: "2026-07-28T06:30:00.000000Z", policy: "deferred",
                              answered_by: "deferred", stage: "epic_plan")])
    end

    it "drains both partitions" do
      queue.approve(digest_a)

      expect(refolded.drained?("alpha", "research")).to be(true)
      expect(refolded.drained?("alpha", "epic_plan")).to be(true)
    end

    it "journals one terminal decision per partition" do
      queue.approve(digest_a)

      signoffs = gate_decisions.select { |record| record["policy"] == "signoff" }
      expect(signoffs.map { |record| record["stage"] }).to contain_exactly("research", "epic_plan")
    end

    it "names every partition it signed off, so none is drained silently" do
      expect(queue.approve(digest_a)).to include("research", "epic_plan")
    end
  end

  # SHOULD-FIX 4: a deferral stamped in the future made `approve` raise a bare
  # ArgumentError from GateDecision's guard -- neither of this class's named
  # errors, no remedy in the message -- and wedged the item until the wall clock
  # caught up, while the listing rendered "waiting -3600s".
  describe "a deferral stamped in the future" do
    before do
      write_journal("20260728T060000-100.ndjson",
                    [decision(digest: digest_a, at: "2026-07-28T12:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred")])
    end

    it "refuses as a damaged record, naming the skew and what to check" do
      expect { queue.approve(digest_a) }
        .to raise_error(described_class::UnreadableRecord, /future.*clock/mi)
    end

    it "refuses the listing rather than rendering a negative wait" do
      expect { queue.listing }.to raise_error(described_class::UnreadableRecord)
    end

    it "journals nothing" do
      expect { queue.approve(digest_a) }.to raise_error(described_class::UnreadableRecord)

      expect(gate_decisions.none? { |record| record["policy"] == "signoff" }).to be(true)
    end
  end

  # THE RULE: a failed rebuild aborts. It never degrades to an empty queue, and
  # Policy::Drained is never a fallback for a rebuild that failed. A drain
  # surface that silently shows "nothing parked" because the fold blew up is the
  # worst failure this chunk can ship.
  describe "a malformed gate_decision record" do
    before do
      write_journal("20260728T060000-100.ndjson",
                    [decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred"),
                     # `policy` is the field the fold BRANCHES on -- missing, the
                     # record cannot be read as parked or as terminal.
                     decision(digest: digest_b, at: "2026-07-28T06:30:00.000000Z", policy: "deferred",
                              answered_by: "deferred").tap { |record| record.delete("policy") }])
    end

    it "aborts the listing rather than rendering a shorter one" do
      expect { queue.listing }.to raise_error(ArgumentError, /policy/)
    end

    it "aborts approve rather than reporting the digest unknown" do
      expect { queue.approve(digest_a) }.to raise_error(ArgumentError, /policy/)
    end

    it "journals no decision when the rebuild aborted" do
      expect { queue.approve(digest_a) }.to raise_error(ArgumentError)

      expect(gate_decisions.none? { |record| record["policy"] == "signoff" }).to be(true)
    end
  end

  # The evidence discriminator is a literal here because GateEvidence ships no
  # constant for it. Pinned against a real record so the two cannot drift.
  it "spells the evidence journal type the way the producing record does" do
    record = Lain::Approval::Gate::Adjudicator::GateEvidence.missing(
      "no findings", { artifact_digest: digest_a, epic_slug: "alpha", stage: "research", question: "q" }, latency: 1.0
    )

    expect(described_class::EVIDENCE_TYPE).to eq(record.journal_type)
  end

  describe "a deferral whose timestamp cannot be read" do
    before do
      write_journal("20260728T060000-100.ndjson",
                    [decision(digest: digest_a, at: "not-a-timestamp", policy: "deferred",
                              answered_by: "deferred")])
    end

    # A sign-off journals the wait as its latency, and `to_f` would write
    # "answered instantly" -- a measurement nobody made -- into the record.
    it "refuses rather than journaling a latency nobody measured" do
      expect { queue.approve(digest_a) }
        .to raise_error(described_class::UnreadableRecord, /no readable `ts`/)
      expect(gate_decisions.none? { |record| record["policy"] == "signoff" }).to be(true)
    end
  end

  describe "journal discovery" do
    it "folds every session file, because an epic spans days and sessions" do
      write_journal("20260727T060000-100.ndjson",
                    [decision(digest: digest_a, at: "2026-07-27T06:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred")])
      write_journal("20260728T060000-101.ndjson",
                    [decision(digest: digest_b, at: "2026-07-28T06:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred", stage: "epic_plan")])

      expect(queue.listing).to include(digest_a, digest_b)
    end

    it "orders records by ts across files, so an out-of-order filename cannot resurrect a drain" do
      # The sign-off is journaled in the LEXICOGRAPHICALLY EARLIER file but is
      # the LATER record: ordering by filename alone would replay the deferral
      # last and report a signed-off artifact as still parked.
      write_journal("20260728T050000-100.ndjson",
                    [decision(digest: digest_a, at: "2026-07-28T08:00:00.000000Z", policy: "signoff",
                              approved: true, answered_by: "human")])
      write_journal("20260728T090000-101.ndjson",
                    [decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred"),
                     # A genuinely parked item, so the absence asserted below is
                     # a fact about A rather than about an empty rendering -- the
                     # negative assertion would otherwise pass on any failure.
                     decision(digest: digest_b, at: "2026-07-28T06:30:00.000000Z", policy: "deferred",
                              answered_by: "deferred")])

      expect(queue.listing).to include(digest_b)
      expect(queue.listing).not_to include(digest_a)
    end
  end
end
