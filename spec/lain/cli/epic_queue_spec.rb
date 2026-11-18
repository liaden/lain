# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# `lain epic queue` -- the surface a human drains the sign-off queue
# through. The queue is a FOLD over journaled `gate_decision` records, so
# draining is journaling and nothing mutates: `approve`/`deny` append a terminal
# decision and the next fold sees the partition drained.
#
# The rule this file exists to pin: a failed rebuild ABORTS. It never degrades
# to an empty queue, because this is the screen a human reads specifically to
# decide that nothing is outstanding.
RSpec.describe Lain::CLI::EpicQueue do
  subject(:queue) { described_class.new(paths:, clock:, root:) }

  around do |example|
    Dir.mktmpdir { |dir| @state_home = dir and example.run }
  end

  let(:paths) { Lain::Paths.new(env: SpecHome.env({ "XDG_STATE_HOME" => @state_home })) }

  # The home the examples that read an epic back resolve against.
  let(:root) { File.join(@state_home, "project").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:config) { Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg, gates: {})) }
  let(:epics) { Lain::CLI::Epic.new(root:, paths:, config:) }
  let(:home) { Lain::Epic::Home.resolve(config:, paths:, root:, slug: "alpha") }

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
  # shape production actually writes (the sessions_spec `header` idiom).
  def decision(digest:, at:, policy:, verdict: Lain::Epic::GateDecision::Deferred.new, slug: "alpha", stage: "research",
               answered_by: "gate_adjudicator", evidence_digest: nil, reason: nil, **scope)
    Lain::Epic::GateDecision.new(artifact_digest: digest, epic_slug: slug, stage:, verdict:,
                                 answered_by:, policy:, latency: 1.5, evidence_digest:, reason:, **scope)
                            .to_journal.merge("ts" => at)
  end

  # The approvals a later stage's sign-off stands on: approving it opens its
  # stage only over earlier ones approved at the bytes their artifacts hold now,
  # as a verdict does. An artifact the home lacks is stamped at a digest none has.
  def approvals(*stages, at: "2026-07-28T05:00:00.000000Z", **scope)
    stages.map do |stage|
      digest = digests.digest(scope.fetch(:slug, "alpha"), stage, scope[:issue_id]) || "blake3:#{stage}-gone"
      decision(digest:, at:, policy: "signoff", verdict: Lain::Approval::Verdict::Approve.new, answered_by: "human",
               stage:, **scope)
    end
  end

  def digests = Lain::CLI::EpicSubmit::Digests.new(config:, paths:, root:)

  def evidence(digest:, at:, question:, slug: "alpha", stage: "research", text: "the spike found two answers")
    gated = { artifact_digest: digest, epic_slug: slug, stage:, question: }
    Lain::Epic::Gate::Adjudicator::GateEvidence.gathered(text, gated, latency: 2.0)
                                               .to_journal.merge("ts" => at)
  end

  def deferred_wait(digest:, stage:, sha:, question:, at: "2026-07-28T06:20:00.000000Z", issue_id: "a", slug: "alpha")
    Lain::Telemetry::AwaitingHuman.new(kind: "gate", ref: digest, summary: question, deferred: true, epic_slug: slug,
                                       stage:, issue_id:, sha:).to_journal.merge("ts" => at)
  end

  # A String goes down verbatim, so a fixture can write a genuinely damaged line
  # (truncated, or never JSON at all) rather than a JSON-encoded String.
  def write_journal(name, records)
    lines = records.map { |record| record.is_a?(String) ? record : JSON.generate(record) }
    path = File.join(paths.filing_dir(root:), name)
    File.write(path, "#{lines.join("\n")}\n")
    path
  end

  def journal_records
    Dir.children(paths.filing_dir(root:)).select { |name| name.end_with?(".ndjson") }.sort
       .flat_map { |name| Lain::Journal.records(File.foreach(File.join(paths.filing_dir(root:), name))).to_a }
  end

  def gate_decisions = journal_records.select { |record| record["type"] == "gate_decision" }

  def refolded = Lain::Epic::SignoffQueue.from_journal(journal_records)

  # Scenario: the overnight queue still finds parked gates
  describe "a gate the deferred policy parked overnight" do
    subject(:queue) { described_class.new(paths:, clock: -> { Time.now.utc + 3600 }, root:) }

    let(:artifact) do
      Data.define(:digest, :gate_question).new(digest: digest_b, gate_question: "Approve the research for alpha?")
    end

    before do
      journal = Lain::Journal.open(paths:, root:)
      gate = Lain::Epic::Gate.new(journal:, timeout: 1)
      policy = Lain::Epic::Gate::Policy::Deferred.new(queue: Lain::Epic::SignoffQueue.new, digests:, journal:)
      Sync { policy.decide(artifact, gate:, stage: "research", epic_slug: "alpha") }
      journal.close
    end

    context "when the question carries its reply instructions" do
      let(:artifact) do
        Data.define(:digest, :gate_question).new(digest: digest_b,
                                                 gate_question: "Approve the research for alpha? Reply y or n.")
      end

      it "lists the whole question, not just its lead sentence" do
        row = queue.listing("alpha").split("\n\n").find { |block| block.include?(digest_b) }

        expect(row).to include("Reply y or n.")
      end
    end

    it "lists it with the question the gate asked" do
      row = queue.listing("alpha").split("\n\n").find { |block| block.include?(digest_b) }

      expect(row).to include("question:  Approve the research for alpha?")
      expect(row).not_to include("not recoverable")
    end
  end

  # An interactive gate's wait is closed by its own decision, and parks nothing.
  it "takes no question from a gate that was waiting on a human rather than parked" do
    open_wait = Lain::Telemetry::AwaitingHuman.new(kind: "gate", ref: digest_c, summary: "the live question",
                                                   epic_slug: "alpha", stage: "research").to_journal
    records = [decision(digest: digest_c, at: "2026-07-28T06:20:00.000000Z", policy: "deferred",
                        answered_by: "deferred"), open_wait.merge("ts" => "2026-07-28T06:20:00.000000Z")]

    rows = described_class.const_get(:Review).new(records, now:).rows

    expect(rows.join).not_to include("the live question")
  end

  # An approved issue plan puts its issue in flight whichever surface approved
  # it: the epic driver launches only issues in flight, so a plan signed off
  # here and left pending would never run.
  describe "approving a parked issue plan" do
    subject(:queue) { described_class.new(paths:, clock:, epics:, root:) }

    def progress = Lain::Epic::Progress.fold(journal_records, graph: home.read_epic, epic_slug: "alpha")

    before do
      home.research.write("the research, such as it is\n")
      home.write_epic(Lain::Epic::Graph.new(issues: [Lain::Epic::Issue.new(id: "a", title: "A"),
                                                     Lain::Epic::Issue.new(id: "b", title: "B")]))
      write_journal("20260728T060000-100.ndjson",
                    [*approvals("research", "epic_plan"),
                     decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred", stage: "issue_plan", issue_id: "a")])
    end

    it "puts that issue in flight and says so, leaving its sibling pending" do
      said = queue.approve(digest_a)

      expect(said).to include("issue a moved pending -> in_flight")
      expect([progress.status("a"), progress.status("b")]).to eq(%w[in_flight pending])
    end

    it "moves nothing when the plan is denied" do
      queue.deny(digest_a)

      expect(progress.status("a")).to eq("pending")
    end

    # An issue's status is folded from the epic's own document, so a plan
    # approved where that document is missing is refused before the sign-off
    # lands, naming the document and where it was looked for -- the real cause,
    # rather than advice to go and stand somewhere else.
    it "refuses when the epic's document is missing, naming it and where it looked, journaling nothing" do
      FileUtils.rm(home.epic.path)

      expect { queue.approve(digest_a) }.to raise_error(described_class::MissingEpicDocument) { |error|
        expect(error.message).to include('"alpha"', "issue_plan", 'issue "a"', home.epic.path)
        expect(error.message).not_to include("inside the project")
      }
      expect(gate_decisions.count { |record| record["artifact_digest"] == digest_a }).to eq(1)
    end
  end

  # Scenario: a queue approval of research advances the epic
  #
  # Research is approved before plan-epic writes epic.md, so these examples
  # hold research.md alone, as a real epic does at this gate.
  describe "approving a parked epic-wide stage" do
    subject(:queue) { described_class.new(paths:, clock:, epics:, root:) }

    before do
      home.research.write("the research, such as it is\n")
      write_journal("20260728T060000-100.ndjson",
                    [decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred")])
    end

    def stage_events
      journal_records.select { |record| record["type"] == "stage_transition" }
                     .map { |record| record.values_at("stage", "event") }
    end

    it "clears research and advances the epic with no epic.md written" do
      said = queue.approve(digest_a)

      expect(said).to include("signed off #{digest_a}", "research completed, epic_plan started")
      expect(refolded.drained?("alpha", "research")).to be(true)
      expect(stage_events).to eq([%w[research completed], %w[epic_plan started]])
      expect(epics.stage("alpha").name).to eq("epic_plan")
    end

    it "reads stage epic_plan in lain epic status once plan-epic writes the document" do
      queue.approve(digest_a)
      home.write_epic(Lain::Epic::Graph.new(issues: [Lain::Epic::Issue.new(id: "a", title: "A")]))

      expect(epics.status("alpha")).to include("stage epic_plan")
    end

    it "advances nothing when research is denied" do
      queue.deny(digest_a)

      expect(stage_events).to be_empty
      expect(epics.stage("alpha").name).to eq("research")
    end
  end

  # Scenario: a held gate is listed, and approving it drains it
  describe "a gate a human held" do
    subject(:queue) { described_class.new(paths:, clock:, epics:, root:) }

    before do
      home.research.write("the research, such as it is\n")
      write_journal("20260728T060000-100.ndjson",
                    [decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "interactive",
                              verdict: Lain::Approval::Verdict::Hold.new(note: "after lunch"), answered_by: "human")])
    end

    it "lists it as held, with how to answer it" do
      row = queue.listing.split("\n\n").find { |block| block.include?(digest_a) }

      expect(row).to include("held", "after lunch", "lain epic approve #{digest_a}", "lain epic deny #{digest_a}")
    end

    it "counts it in the headline" do
      expect(queue.listing.lines.first).to eq("1 gate waiting for sign-off (1 held), ready-to-review first\n")
    end

    it "approves it, and the queue no longer lists it" do
      said = queue.approve(digest_a)

      expect(said).to include("signed off #{digest_a}")
      expect(described_class.new(paths:, clock:, root:).listing).to include("nothing parked for sign-off")
      expect(refolded.held("alpha", "research")).to be_empty
    end

    it "denies it, and the queue no longer lists it" do
      queue.deny(digest_a, reason: "no")

      expect(described_class.new(paths:, clock:, root:).listing).to include("nothing parked for sign-off")
    end
  end

  # Scenario: implementation rows name their issue
  describe "parked gates for two issues" do
    before do
      home.research.write("the research, such as it is\n")
      home.write_epic(Lain::Epic::Graph.new(issues: [Lain::Epic::Issue.new(id: "greet", title: "Greet"),
                                                     Lain::Epic::Issue.new(id: "shout", title: "Shout")]))
      home.issue("greet").write("the prose for greet\n")
      write_journal("20260728T060000-100.ndjson",
                    [*approvals("research", "epic_plan"), *approvals("issue_plan", issue_id: "greet"),
                     decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred", stage: "implementation", issue_id: "greet"),
                     decision(digest: digest_b, at: "2026-07-28T06:10:00.000000Z", policy: "deferred",
                              answered_by: "deferred", stage: "implementation", issue_id: "shout")])
    end

    def row_holding(digest) = queue.listing.split("\n\n").find { |row| row.include?(digest) }

    it "names each row's issue" do
      expect(row_holding(digest_a).lines.first).to include("implementation", "issue greet")
      expect(row_holding(digest_b).lines.first).to include("implementation", "issue shout")
    end

    it "names the issue in the sign-off it confirms" do
      expect(queue.approve(digest_a)).to include("alpha/implementation/greet")
    end

    it "names the issue beside each digest when the one typed is parked nowhere" do
      expect { queue.approve(digest_c) }.to raise_error(described_class::UnknownDigest, %r{alpha/implementation/greet})
    end
  end

  # The evidence cell tells a gate that never spiked from a spike that came
  # back empty: only the second is a failure worth reading into.
  describe "the evidence a parked row shows" do
    def parked(digest, at:) = decision(digest:, at:, policy: "deferred", answered_by: "deferred")

    it "says no spike ran when the policy gathered none" do
      write_journal("20260728T060000-100.ndjson", [parked(digest_a, at: "2026-07-28T06:00:00.000000Z")])

      expect(queue.listing).to include("evidence:  <none -- no spike ran>")
      expect(queue.listing).not_to include("the spike did not answer")
    end

    it "says the spike did not answer when one ran and gathered nothing" do
      spike = Lain::Epic::Gate::Adjudicator::GateEvidence.missing(
        "no findings", { artifact_digest: digest_a, epic_slug: "alpha", stage: "research", question: "q" },
        latency: 1.0
      ).to_journal.merge("ts" => "2026-07-28T05:59:00.000000Z")
      write_journal("20260728T060000-100.ndjson", [spike, parked(digest_a, at: "2026-07-28T06:00:00.000000Z")])

      expect(queue.listing).to include("evidence:  <none gathered -- the spike did not answer>")
    end
  end

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
                                  "verdict" => "approve", "answered_by" => "human", "policy" => "signoff")
      expect(terminal).not_to have_key("approved")
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

    it "confirms that it signed the artifact off" do
      expect(queue.approve(digest_a)).to start_with("signed off #{digest_a}\n  alpha/research — approved by human")
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

    # Scenario: a slug passed where a digest belongs says so
    it "refuses a slug by saying approve wants a digest, not narrowing the listing" do
      expect { queue.approve("alpha") }
        .to raise_error(described_class::UnknownDigest, /approve names a parked artifact by digest.*"alpha"/m)
    end

    it "still lists what is parked when the argument does not look like a digest" do
      expect { queue.approve("alpha") }.to raise_error(described_class::UnknownDigest, /#{Regexp.escape(digest_a)}/)
    end

    # Scenario: an unknown digest is unchanged
    it "leaves the digest-shaped refusal wording as it was" do
      message = begin
        queue.approve(digest_c)
      rescue described_class::UnknownDigest => e
        e.message
      end

      expect(message).to start_with("no parked sign-off for #{digest_c.inspect}")
      expect(message).not_to include("names a parked artifact by digest")
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
      expect(terminal).to include("verdict" => "deny", "answered_by" => "human", "policy" => "signoff")
      expect(terminal).not_to have_key("approved")
    end

    it "journals the reason a denial gave as the verdict's note" do
      queue.deny(digest_a, reason: "wrong crate")

      terminal = gate_decisions.find { |record| record["policy"] == "signoff" }
      expect(terminal).to include("verdict" => "deny", "reason" => "wrong crate")
    end

    # A denial signs nothing off, so the confirmation says what was done.
    it "confirms that it denied the artifact, not that it signed it off" do
      said = queue.deny(digest_a)

      expect(said).to start_with("denied #{digest_a}\n  alpha/research — denied by human")
      expect(said).not_to include("signed off")
    end

    it "records the human's rationale when one is given" do
      queue.deny(digest_a, reason: "the backfill is unbounded")

      terminal = gate_decisions.find { |record| record["policy"] == "signoff" }
      expect(terminal["reason"]).to eq("the backfill is unbounded")
    end

    # Same refusal, spelled with the verb actually typed.
    it "refuses a slug by saying deny wants a digest" do
      expect { queue.deny("alpha") }
        .to raise_error(described_class::UnknownDigest, /deny names a parked artifact by digest.*"alpha"/m)
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
                 verdict: Lain::Approval::Verdict::Approve.new, answered_by: "human")
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

    describe "an implementation gate parked with its question and test result" do
      let(:commit) { "8b6b677" }
      let(:question) { "Approve the implementation stage for \"alpha\"? (issue a, #{commit}, tests: 1 error)" }

      before do
        write_journal("20260728T062000-102.ndjson",
                      [*approvals("research", "epic_plan", "issue_plan"),
                       decision(digest: digest_c, at: "2026-07-28T06:20:00.000000Z", policy: "deferred",
                                answered_by: "deferred", stage: "implementation", issue_id: "a"),
                       deferred_wait(digest: digest_c, stage: "implementation", sha: commit, question:),
                       Lain::Telemetry::TestsRan.from(Struct.new(:passed, :failed, :errors).new([], [], [3]),
                                                      issue_id: "a", sha: commit)
                                                .to_journal.merge("ts" => "2026-07-28T06:19:00.000000Z")])
      end

      it "shows the question and a tests line, and neither reads as unrecoverable" do
        row = queue.listing("alpha").split("\n\n").find { |block| block.include?(digest_c) }

        expect(row).to include("question:  #{question}", "tests:     0 passed, 1 error")
        expect(row).not_to include("not recoverable")
      end
    end

    describe "a parked row's test counts" do
      def tests_line(passed:, failed:, errors:)
        ran = Lain::Telemetry::TestsRan.from(Struct.new(:passed, :failed, :errors).new(passed, failed, errors),
                                             issue_id: "a", sha: "8b6b677").to_journal
        records = [decision(digest: digest_c, at: "2026-07-28T06:20:00.000000Z", policy: "deferred",
                            answered_by: "deferred", stage: "implementation", issue_id: "a"),
                   deferred_wait(digest: digest_c, stage: "implementation", sha: "8b6b677", question: "q?"),
                   ran.merge("ts" => "2026-07-28T06:19:00.000000Z")]
        described_class.const_get(:Review).new(records, now:).rows.join[/tests: .*/]
      end

      it "says each count with its word" do
        expect(tests_line(passed: [1, 2, 3], failed: [4], errors: [5])).to eq("tests:     3 passed, 1 failed, 1 error")
      end

      it "pluralizes errors" do
        expect(tests_line(passed: [1], failed: [], errors: [5, 6])).to eq("tests:     1 passed, 2 errors")
      end
    end

    it "shows the later deferral's reason when an artifact was deferred twice" do
      records = ["first try", second = "second try"].each_with_index.map do |reason, at|
        decision(digest: digest_c, at: "2026-07-28T06:2#{at}:00.000000Z", policy: "deferred",
                 answered_by: "deferred", reason:)
      end

      rows = described_class.const_get(:Review).new(records, now:).rows

      expect(rows.map(&:reason)).to eq([second])
    end

    it "keeps the deferral's reason and park time when a human later holds the parked digest" do
      records = [decision(digest: digest_c, at: "2026-07-28T06:20:00.000000Z", policy: "deferred",
                          answered_by: "deferred", reason: "unsure at park"),
                 decision(digest: digest_c, at: "2026-07-28T07:20:00.000000Z", policy: "signoff",
                          verdict: Lain::Approval::Verdict::Hold.new, answered_by: "human", reason: "human hold note")]

      rows = described_class.const_get(:Review).new(records, now:).rows

      expect(rows.map { [_1.reason, _1.parked_at] })
        .to eq([["unsure at park", Time.iso8601("2026-07-28T06:20:00Z")]])
    end

    it "walks the records once to build every row" do
      commit = "8b6b677"
      records = [*approvals("research", "epic_plan", "issue_plan"),
                 decision(digest: digest_c, at: "2026-07-28T06:20:00.000000Z", policy: "deferred",
                          answered_by: "deferred", stage: "implementation", issue_id: "a"),
                 deferred_wait(digest: digest_c, stage: "implementation", sha: commit, question: "q?"),
                 Lain::Telemetry::TestsRan.from(Struct.new(:passed, :failed, :errors).new([1], [], []),
                                                issue_id: "a", sha: commit)
                                          .to_journal.merge("ts" => "2026-07-28T06:19:00.000000Z")]
      walks = 0
      walked = Enumerator.new do |yielder|
        walks += 1
        records.each { |record| yielder << record }
      end

      rows = described_class.const_get(:Review).new(walked, now:).rows

      expect(rows.join).to include("question:  q?", "tests:     1 passed")
      expect(walks).to eq(1)
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
      expect(described_class.new(paths:, clock:, root:).listing).to eq(first)
    end
  end

  describe "the project root it files under" do
    let(:project) { instance_double(Lain::Project, root:) }

    before { allow(Lain::Project::Resolver).to receive(:default_project).and_return(project) }

    it "asks the resolver once, at construction, when no root is given" do
      built = described_class.new(paths:, clock:)
      expect(Lain::Project::Resolver).to have_received(:default_project).once

      2.times { built.listing }
      expect(Lain::Project::Resolver).to have_received(:default_project).once
    end

    it "does not ask the resolver when a root is given" do
      described_class.new(paths:, clock:, root:).listing

      expect(Lain::Project::Resolver).not_to have_received(:default_project)
    end
  end

  describe "an empty queue" do
    it "names the directory it folded, so 'nothing outstanding' is checkable" do
      expect(queue.listing).to include(paths.filing_dir(root:))
    end

    it "reports what it understood, not merely how many files it opened" do
      write_journal("20260728T060000-100.ndjson",
                    [decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "signoff",
                              verdict: Lain::Approval::Verdict::Approve.new, answered_by: "human")])

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

    # Another writer's JSON line is valid and simply is not ours. Warning about
    # it would cry wolf on every session it touched.
    it "stays quiet about a foreign JSON record" do
      write_journal("20260728T060000-100.ndjson",
                    [{ "ts" => "2026-07-28T06:00:00.000000Z", "level" => "INFO", "target" => "lain_core" }])

      expect(queue.listing).not_to include("could not be parsed")
    end
  end

  # The same bytes can be gated at two stages, so one digest can
  # be parked twice. Signing off "the digest" signs off each place it waits, and
  # the confirmation names them -- leaving one parked with no sign to say so is
  # exactly the failure this surface exists to prevent.
  describe "a digest parked in two partitions" do
    # The same bytes at both stages: the research as it stands, so the boundary reads its approval.
    let(:digest_a) { Lain::Epic::Submission.research(text: "the research, such as it is\n", slug: "alpha").digest }

    before do
      home.research.write("the research, such as it is\n")
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

  # Scenario: approving a later stage over a denied earlier one is refused
  #
  # A sign-off advances the epic exactly as a verdict does, so it meets the
  # boundary a verdict meets: a withdrawn research approval holds epic_plan.
  describe "approving a later stage over a denied earlier one" do
    subject(:queue) { described_class.new(paths:, clock:, epics:, root:) }

    before do
      home.research.write("the research, such as it is\n")
      write_journal("20260728T060000-100.ndjson",
                    [decision(digest: digest_c, at: "2026-07-28T05:00:00.000000Z", policy: "signoff",
                              verdict: Lain::Approval::Verdict::Approve.new, answered_by: "human"),
                     decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred", stage: "epic_plan"),
                     decision(digest: digest_b, at: "2026-07-28T06:30:00.000000Z", policy: "signoff",
                              verdict: Lain::Approval::Verdict::Deny.new, answered_by: "human")])
    end

    # A deny advances nothing, so it drains a later stage whatever stands
    # before it.
    it "still records a deny over the denied research" do
      expect(queue.deny(digest_a)).to start_with("denied #{digest_a}")
      expect(refolded.drained?("alpha", "epic_plan")).to be(true)
    end

    it "refuses naming the research stage, and journals no sign-off and no stage transition" do
      expect { queue.approve(digest_a) }.to raise_error(Lain::Epic::StageBlocked, /alpha.*epic_plan.*research/m)
      expect(gate_decisions.count { |record| record["artifact_digest"] == digest_a }).to eq(1)
      expect(journal_records.none? { |record| record["type"] == "stage_transition" }).to be(true)
    end
  end

  # The same boundary a submit meets: research stands approved only at the bytes on disk now.
  describe "approving epic_plan over a research edited since its approval" do
    subject(:queue) { described_class.new(paths:, clock:, epics:, root:) }

    before do
      home.research.write("v1\n")
      write_journal("20260728T060000-100.ndjson",
                    [decision(digest: Lain::Epic::Submission.research(text: "v1\n", slug: "alpha").digest,
                              at: "2026-07-28T05:00:00.000000Z", policy: "signoff",
                              verdict: Lain::Approval::Verdict::Approve.new, answered_by: "human"),
                     decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred", stage: "epic_plan")])
    end

    it "refuses naming research as changed since its approval, journaling no sign-off" do
      home.research.write("v2\n")

      expect { queue.approve(digest_a) }.to raise_error(Lain::Epic::StageBlocked) { |error|
        expect(error.message)
          .to start_with('epic "alpha" cannot open its epic_plan stage -- research changed since its approval; ' \
                         "resubmit research")
      }
      expect(gate_decisions.count { |record| record["artifact_digest"] == digest_a }).to eq(1)
    end

    it "signs off while the research is the approved one" do
      expect(queue.approve(digest_a)).to include("signed off #{digest_a}")
    end
  end

  # Two issues' plans under one digest keep the order they were parked in.
  describe "a digest parked for two issues at one stage" do
    before do
      write_journal("20260728T060000-100.ndjson",
                    [decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred", stage: "issue_plan", issue_id: "b"),
                     decision(digest: digest_a, at: "2026-07-28T06:30:00.000000Z", policy: "deferred",
                              answered_by: "deferred", stage: "issue_plan", issue_id: "a")])
    end

    it "signs them off oldest park first" do
      queue.deny(digest_a)

      signoffs = gate_decisions.select { |record| record["policy"] == "signoff" }
      expect(signoffs.map { |record| record["issue_id"] }).to eq(%w[b a])
    end
  end

  # Scenario: a digest parked in 2 partitions approves in stage order
  #
  # The epic_plan park is the older one and carries evidence, so both the fold
  # and the listing reach it first; the boundary still needs research signed
  # off before it.
  describe "a digest parked in two partitions, the later stage parked first" do
    subject(:queue) { described_class.new(paths:, clock:, epics:, root:) }

    # The same bytes at both stages: the research as it stands, so the boundary reads its approval.
    let(:digest_a) { Lain::Epic::Submission.research(text: "the research, such as it is\n", slug: "alpha").digest }

    before do
      home.research.write("the research, such as it is\n")
      write_journal("20260728T060000-100.ndjson",
                    [decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred", stage: "epic_plan", evidence_digest: evidence_a),
                     evidence(digest: digest_a, at: "2026-07-28T06:00:01.000000Z", stage: "epic_plan",
                              question: "Is the plan whole?"),
                     decision(digest: digest_a, at: "2026-07-28T06:30:00.000000Z", policy: "deferred",
                              answered_by: "deferred")])
    end

    def stage_events
      journal_records.select { |record| record["type"] == "stage_transition" }
                     .map { |record| record.values_at("stage", "event") }
    end

    it "signs off research, then epic_plan, and moves the epic in that order" do
      queue.approve(digest_a)

      signoffs = gate_decisions.select { |record| record["policy"] == "signoff" }
      expect(signoffs.map { |record| record["stage"] }).to eq(%w[research epic_plan])
      expect(stage_events).to eq([%w[research completed], %w[epic_plan started],
                                  %w[epic_plan completed], %w[issue_plan started]])
    end
  end

  # A deferral stamped in the future made `approve` raise a bare
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

  # THE RULE: a failed rebuild aborts. It never degrades to an empty queue. A drain
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
      expect { queue.listing }.to raise_error(described_class::UnreadableRecord, /policy/)
    end

    it "aborts approve rather than reporting the digest unknown" do
      expect { queue.approve(digest_a) }.to raise_error(described_class::UnreadableRecord, /policy/)
    end

    it "journals no decision when the rebuild aborted" do
      expect { queue.approve(digest_a) }.to raise_error(described_class::UnreadableRecord)

      expect(gate_decisions.none? { |record| record["policy"] == "signoff" }).to be(true)
    end
  end

  # Scenario: a malformed but parseable gate_decision refuses by name
  describe "a gate_decision whose verdict field is not a verdict word" do
    before do
      write_journal("20260728T060000-100.ndjson",
                    [decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred"),
                     decision(digest: digest_a, at: "2026-07-28T06:30:00.000000Z", policy: "signoff",
                              answered_by: "human").merge("verdict" => "maybe")])
    end

    it "refuses the listing and the approval as a Lain::Error, in one line naming the record" do
      [-> { queue.listing }, -> { queue.approve(digest_a) }].each do |command|
        expect(&command).to raise_error(Lain::Error) { |error|
          expect(error.message).to include("gate_decision", digest_a, "alpha/research", "verdict")
          expect(error.message).not_to include("\n")
        }
      end
    end
  end

  # A torn line under a sign-off: the listing is the one reader that goes on
  # rendering over damage, because it says so; a decision refuses to be made
  # over a fold it could not read whole.
  describe "a torn gate_decision line" do
    let(:torn) do
      JSON.generate(decision(digest: digest_b, at: "2026-07-28T06:30:00.000000Z", policy: "deferred",
                             answered_by: "deferred")).then { |line| line[0, line.size / 2] }
    end

    before do
      write_journal("20260728T060000-100.ndjson",
                    [decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred"), torn])
    end

    it "still lists, warning that the listing is not proven complete" do
      expect(queue.listing).to include(digest_a, "1 line could not be parsed", "not proven")
    end

    it "refuses approve, naming the file and the line, and journals nothing" do
      expect { queue.approve(digest_a) }
        .to raise_error(Lain::CLI::SessionJournals::Unreadable, /20260728T060000-100\.ndjson.*line 2/)
      expect(gate_decisions.none? { |record| record["policy"] == "signoff" }).to be(true)
    end

    # The listing's tolerance is its own read, not a cache the deciding verbs
    # fall back on: one instance listing first and approving second must
    # still refuse.
    it "refuses approve on the same instance that just listed" do
      queue.listing

      expect { queue.approve(digest_a) }.to raise_error(Lain::CLI::SessionJournals::Unreadable)
      expect(gate_decisions.none? { |record| record["policy"] == "signoff" }).to be(true)
    end

    it "refuses deny the same way" do
      expect { queue.deny(digest_a) }.to raise_error(Lain::CLI::SessionJournals::Unreadable, /nothing was decided/)
    end
  end

  # A whole record wearing a sign-off's fields under a type nothing folds could
  # be a deferral whose type was damaged. The listing says so, by that type;
  # the deciding verbs refuse, as they do over a torn line.
  describe "a gate-shaped record under an unknown type" do
    let(:misfiled) do
      decision(digest: digest_b, at: "2026-07-28T06:30:00.000000Z", policy: "deferred", answered_by: "deferred")
        .merge("type" => "gate_decisoin")
    end

    before do
      write_journal("20260728T060000-100.ndjson",
                    [decision(digest: digest_a, at: "2026-07-28T06:00:00.000000Z", policy: "deferred",
                              answered_by: "deferred"), misfiled])
    end

    it "still lists, warning that a record has an unknown type, naming it, and not that it could not be parsed" do
      listing = queue.listing

      expect(listing).to include(digest_a, "unknown type", '"gate_decisoin"', "not proven")
      expect(listing).not_to include("could not be parsed")
    end

    it "refuses approve, naming the file, the line and the type, and journals nothing" do
      expect { queue.approve(digest_a) }
        .to raise_error(Lain::CLI::SessionJournals::Unreadable, /20260728T060000-100\.ndjson.*line 2.*"gate_decisoin"/)
      expect(gate_decisions.none? { |record| record["policy"] == "signoff" }).to be(true)
    end

    it "refuses deny the same way" do
      expect { queue.deny(digest_a) }.to raise_error(Lain::CLI::SessionJournals::Unreadable, /"gate_decisoin"/)
      expect(gate_decisions.none? { |record| record["policy"] == "signoff" }).to be(true)
    end
  end

  # The evidence discriminator is a literal here because GateEvidence ships no
  # constant for it. Pinned against a real record so the two cannot drift.
  it "spells the evidence journal type the way the producing record does" do
    record = Lain::Epic::Gate::Adjudicator::GateEvidence.missing(
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
                              verdict: Lain::Approval::Verdict::Approve.new, answered_by: "human")])
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
