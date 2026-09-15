# frozen_string_literal: true

require "stringio"

# Approval::SignoffQueue holds the artifact gates a Deferred policy parked for a
# human to sign off later. It is a FOLD over journaled gate_decisions -- parked
# is "a deferral with no later terminal decision for the same digest+epic+stage"
# -- so a session that dies loses no sign-off, and the live queue is only the
# convenience view of a record that already exists.
#
# It is deliberately NOT Approval::Queue: that one is effect-scoped (it parks one
# tool call and blocks a fiber on it). Nothing parks here; a deferral returns at
# once having refused.
RSpec.describe Lain::Approval::SignoffQueue do
  # ONE sentence for a damaged sign-off record, whichever fold reaches it: the
  # queue's own and the gate registry's both build their refusal here.
  describe described_class::UnreadableRecord, ".for" do
    it "names the record's digest, its partition and the cause, in one line" do
      record = { "artifact_digest" => "blake3:torn", "epic_slug" => "demo", "stage" => "issue_plan",
                 "issue_id" => "a" }

      refusal = described_class.for(record, ArgumentError.new("approved must be true or false, got maybe"))

      expect(refusal).to be_a(Lain::Error)
      expect(refusal.message).to eq('the gate_decision record for "blake3:torn" in "demo/issue_plan/a" cannot be ' \
                                    "read (approved must be true or false, got maybe) -- repair the line or move " \
                                    "its session file aside; nothing was decided")
    end
  end

  def park(queue, digest: "blake3:plan", epic_slug: "alpha", stage: "research", **overrides)
    queue.park(artifact_digest: digest, epic_slug:, stage:, **overrides)
  end

  # A journal a fold can be read back out of, the way a real session's is.
  def journaled(*decisions)
    io = StringIO.new
    journal = Lain::Journal.new(io:)
    decisions.each { |decision| journal.record(decision) }
    io.string.lines
  end

  def decision(policy:, approved: false, digest: "blake3:plan", epic_slug: "alpha", stage: "research", **overrides)
    Lain::Approval::GateDecision.new(artifact_digest: digest, epic_slug:, stage:, approved:,
                                     answered_by: policy, policy:, latency: 0.1, **overrides)
  end

  def deferral(**overrides) = decision(policy: described_class::DEFERRED_POLICY, **overrides)
  def approval(**overrides) = decision(policy: "signoff", approved: true, **overrides)

  describe "parking" do
    it "holds one item per (digest, epic, stage) address" do
      queue = described_class.new
      park(queue)

      expect(queue.count).to eq(1)
      expect(queue.first).to have_attributes(artifact_digest: "blake3:plan", epic_slug: "alpha",
                                             stage: "research")
    end

    it "is idempotent on that address -- parking the same gate twice is one sign-off" do
      queue = described_class.new
      park(queue)
      park(queue)

      expect(queue.count).to eq(1)
    end

    it "keeps the same artifact in two epics apart" do
      queue = described_class.new
      park(queue, epic_slug: "alpha")
      park(queue, epic_slug: "beta")

      expect(queue.count).to eq(2)
    end

    it "carries the gate question, so a morning review can read what it is answering" do
      queue = described_class.new
      park(queue, question: "Approve the epic plan?")

      expect(queue.first.question).to eq("Approve the epic plan?")
    end

    it "carries an evidence digest when one was gathered, and nil when none was" do
      queue = described_class.new
      park(queue, evidence_digest: "blake3:spike")
      park(queue, digest: "blake3:other")

      expect(queue.map(&:evidence_digest)).to contain_exactly("blake3:spike", nil)
    end

    it "refuses a nil artifact_digest -- a parked sign-off always names what it is holding" do
      expect { park(described_class.new, digest: nil) }.to raise_error(ArgumentError, /artifact_digest/)
    end

    it "refuses a blank epic_slug -- it is half the partition key" do
      expect { park(described_class.new, epic_slug: "") }.to raise_error(ArgumentError, /epic_slug/)
    end

    it "refuses a blank stage -- the other half" do
      expect { park(described_class.new, stage: nil) }.to raise_error(ArgumentError, /stage/)
    end
  end

  describe "#drained? -- the (epic_slug, stage) partition" do
    it "is drained when nothing was ever parked there" do
      expect(described_class.new.drained?("alpha", "research")).to be(true)
    end

    it "is not drained while an item sits in that partition" do
      queue = described_class.new
      park(queue, epic_slug: "alpha", stage: "research")

      expect(queue.drained?("alpha", "research")).to be(false)
    end

    it "keys on BOTH members, so a sibling epic is unaffected" do
      queue = described_class.new
      park(queue, epic_slug: "alpha", stage: "research")

      expect(queue.drained?("beta", "research")).to be(true)
      expect(queue.drained?("alpha", "epic_plan")).to be(true)
    end

    it "reads a Symbol stage the same as its String, since the journal stores the String" do
      queue = described_class.new
      park(queue, stage: "research")

      expect(queue.drained?(:alpha, :research)).to be(false)
    end

    it "is drained again once the item is drained by address" do
      queue = described_class.new
      park(queue)
      drained = queue.drain(artifact_digest: "blake3:plan", epic_slug: "alpha", stage: "research")

      expect(drained).to have_attributes(artifact_digest: "blake3:plan")
      expect(queue.drained?("alpha", "research")).to be(true)
    end

    # park keyed on the raw object while drain keyed on its #to_s, so anything
    # that was not already a String parked under an address drain could never
    # reconstruct: the item was unwedgeable and its partition never opened
    # again. Partition interns both of ITS members for exactly this reason.
    it "drains what it parked when the digest was not a String" do
      queue = described_class.new
      park(queue, digest: :sym_digest)

      queue.drain(artifact_digest: :sym_digest, epic_slug: "alpha", stage: "research")

      expect(queue.drained?("alpha", "research")).to be(true)
    end

    it "reads a parked non-String digest back as the String the journal stores" do
      queue = described_class.new
      park(queue, digest: :sym_digest)

      expect(queue.first.artifact_digest).to eq("sym_digest")
    end

    # Reaching for the ivar because the defect is invisible from outside:
    # drained? and each both read correctly over a leftover empty partition, and
    # the only symptom is a key space that grows for the life of the process. An
    # epic run spans days, so "correct but unbounded" is still a defect.
    it "forgets the partition itself once its last item drains" do
      queue = described_class.new
      park(queue, epic_slug: "alpha", stage: "research")
      park(queue, epic_slug: "beta", stage: "research", digest: "blake3:beta")

      queue.drain(artifact_digest: "blake3:plan", epic_slug: "alpha", stage: "research")

      expect(queue.instance_variable_get(:@parked).keys.map(&:epic_slug)).to eq(["beta"])
    end

    it "keeps a partition that still holds something" do
      queue = described_class.new
      park(queue, digest: "blake3:one")
      park(queue, digest: "blake3:two")

      queue.drain(artifact_digest: "blake3:one", epic_slug: "alpha", stage: "research")

      expect(queue.drained?("alpha", "research")).to be(false)
      expect(queue.instance_variable_get(:@parked).size).to eq(1)
    end

    it "answers nil when draining an address that was never parked" do
      expect(described_class.new.drain(artifact_digest: "blake3:nope", epic_slug: "alpha",
                                       stage: "research")).to be_nil
    end
  end

  describe "#parked -- one partition's items, for the review surface" do
    it "narrows to the partition asked for" do
      queue = described_class.new
      park(queue, epic_slug: "alpha", stage: "research")
      park(queue, epic_slug: "beta", stage: "research", digest: "blake3:beta")

      expect(queue.parked("alpha", "research").map(&:artifact_digest)).to eq(["blake3:plan"])
    end

    it "enumerates everything through #each, in parking order" do
      queue = described_class.new
      park(queue, digest: "blake3:one")
      park(queue, digest: "blake3:two")

      expect(queue.map(&:artifact_digest)).to eq(%w[blake3:one blake3:two])
    end
  end

  describe "the queue is a fold, not a file" do
    it "is drained when a deferral is followed by an approval for the same digest and stage" do
      queue = described_class.from_journal(journaled(deferral, approval))

      expect(queue.drained?("alpha", "research")).to be(true)
      expect(queue.to_a).to be_empty
    end

    it "holds the deferral when no later decision answers it" do
      queue = described_class.from_journal(journaled(deferral))

      expect(queue.drained?("alpha", "research")).to be(false)
      expect(queue.first.artifact_digest).to eq("blake3:plan")
    end

    it "treats a later DENIAL as terminal too -- a refused artifact is not awaiting sign-off" do
      queue = described_class.from_journal(journaled(deferral, decision(policy: "signoff", approved: false)))

      expect(queue.to_a).to be_empty
    end

    it "re-parks when the deferral is the LATER record -- the fold is ordered" do
      queue = described_class.from_journal(journaled(approval, deferral))

      expect(queue.drained?("alpha", "research")).to be(false)
    end

    it "drains only the matching partition, never a sibling epic's" do
      queue = described_class.from_journal(journaled(deferral(epic_slug: "alpha"), deferral(epic_slug: "beta"),
                                                     approval(epic_slug: "beta")))

      expect(queue.map(&:epic_slug)).to eq(["alpha"])
    end

    it "recovers the evidence digest, which the decision record carries" do
      queue = described_class.from_journal(journaled(deferral(evidence_digest: "blake3:spike")))

      expect(queue.first.evidence_digest).to eq("blake3:spike")
    end

    # The one thing a rebuild cannot know. GateDecision's wire shape is closed
    # (designed once, day one), and the question is the ARTIFACT's to render --
    # a reader holding the digest re-derives it rather than reading it here.
    it "leaves the question nil, since the decision record never carried it" do
      queue = described_class.from_journal(journaled(deferral))

      expect(queue.first.question).to be_nil
    end

    it "skips journal lines that are not gate_decisions" do
      entries = journaled(deferral) + ["not json at all\n", %({"type":"tool_output"}\n)]

      expect(described_class.from_journal(entries).count).to eq(1)
    end

    # The fold BRANCHES on `policy`, so `policy` is the field it must be able to
    # trust. A record missing it used to fall to the terminal side and drain a
    # sign-off nobody answered -- after which drained? says true and the next
    # stage's gates open over unreviewed work. Refusing is the only answer that
    # is safe in BOTH directions: skipping a malformed record would lose a
    # deferral just as silently, and a lost deferral reads as drained too.
    it "refuses a gate_decision with no policy key, leaving the parked item where it was" do
      queue = described_class.new
      park(queue)

      expect { queue.apply(decision(policy: "signoff").to_journal.except("policy")) }
        .to raise_error(ArgumentError, /policy/)
      expect(queue.drained?("alpha", "research")).to be(false)
    end

    it "refuses a gate_decision whose policy is null" do
      queue = described_class.new
      park(queue)

      expect { queue.apply(decision(policy: "signoff").to_journal.merge("policy" => nil)) }
        .to raise_error(ArgumentError, /policy/)
      expect(queue.drained?("alpha", "research")).to be(false)
    end

    it "refuses a record with no approved verdict -- the wire shape is nine members, not six" do
      queue = described_class.new
      park(queue)

      expect { queue.apply(decision(policy: "signoff").to_journal.except("approved")) }
        .to raise_error(ArgumentError, /approved/)
      expect(queue.drained?("alpha", "research")).to be(false)
    end

    # from_journal filters on the type; the live one-record-at-a-time path does
    # not get that for free, and it is reachable from any session folding its own
    # journal.
    it "refuses a foreign record type even when it carries all three address keys" do
      queue = described_class.new
      park(queue)

      foreign = { "type" => "tool_output", "artifact_digest" => "blake3:plan",
                  "epic_slug" => "alpha", "stage" => "research" }

      expect { queue.apply(foreign) }.to raise_error(ArgumentError, /type/)
      expect(queue.drained?("alpha", "research")).to be(false)
    end

    it "refuses the whole rebuild when a gate_decision line is malformed, rather than folding past it" do
      lines = journaled(deferral) + [%({"type":"gate_decision","artifact_digest":"d","epic_slug":"alpha",) +
                                     %("stage":"research"}\n)]

      expect { described_class.from_journal(lines) }.to raise_error(described_class::UnreadableRecord, /policy/)
    end

    # The carriers refuse with ArgumentError, which the executable does not map:
    # a damaged line reached a human as a backtrace. The fold is where a record
    # becomes a decision, so the fold is where the refusal gets its name.
    it "refuses a parseable but malformed gate_decision as a named Lain::Error, in one line naming the record" do
      line = decision(policy: "signoff").to_journal.merge("approved" => "maybe")

      expect { described_class.from_journal(journaled(deferral) + [line]) }
        .to raise_error(Lain::Error) { |error|
          expect(error).to be_a(described_class::UnreadableRecord)
          expect(error.message).to include("gate_decision", "blake3:plan", "alpha/research", "approved",
                                           "nothing was decided")
          expect(error.message).not_to include("\n")
        }
    end

    # A misspelt policy is not `deferred`, so it used to fall to the terminal
    # side and drain a sign-off nobody answered. The set is closed: every
    # configurable policy, and the human sign-off the queue surface journals.
    it "refuses a gate_decision whose policy is outside the known set, naming the record" do
      line = deferral.to_journal.merge("policy" => "deferrd")

      expect { described_class.from_journal(journaled(deferral) + [line]) }
        .to raise_error(described_class::UnreadableRecord) { |error|
          expect(error.message).to include("blake3:plan", "alpha/research", "policy", '"deferrd"',
                                           "nothing was decided")
          expect(error.message).not_to include("\n")
        }
    end

    it "folds every policy a decision can be reached by" do
      policies = %w[interactive hands_off deferred adjudicated signoff]
      records = policies.map { |policy| decision(policy:, digest: "blake3:#{policy}").to_journal }

      expect { records.each_with_object(described_class.new) { |record, queue| queue.apply(record) } }
        .not_to raise_error
    end

    # A stage outside the pipeline keys a partition no boundary ever asks
    # about, so a deferral parked there reads as drained everywhere real.
    it "refuses a gate_decision whose stage is outside the pipeline, naming the record" do
      line = deferral.to_journal.merge("stage" => "reserach")

      expect { described_class.from_journal([line]) }
        .to raise_error(described_class::UnreadableRecord, /blake3:plan.*stage.*"reserach"/)
    end

    it "refuses a misspelt policy on the live path too, leaving the parked item where it was" do
      queue = described_class.new
      park(queue)

      expect { queue.apply(approval.to_journal.merge("policy" => "sign_off")) }
        .to raise_error(ArgumentError, /policy/)
      expect(queue.drained?("alpha", "research")).to be(false)
    end

    it "folds a live decision in one record at a time, so a session can stay in step" do
      queue = described_class.new
      queue.apply(deferral.to_journal)

      expect(queue.drained?("alpha", "research")).to be(false)

      queue.apply(approval.to_journal)

      expect(queue.drained?("alpha", "research")).to be(true)
    end
  end

  # Drained cannot tell "answered" from "never asked", so a stage boundary also
  # asks for positive evidence: an approved terminal decision in the partition.
  describe "#approved? -- positive evidence in a partition" do
    it "is false where nothing was ever decided" do
      expect(described_class.new.approved?("alpha", "research")).to be(false)
    end

    it "is true once an approving decision is folded" do
      expect(described_class.from_journal(journaled(approval)).approved?("alpha", "research")).to be(true)
    end

    it "is false for a denial, and for a deferral that parks" do
      denied = described_class.from_journal(journaled(decision(policy: "signoff", approved: false)))

      expect(denied.approved?("alpha", "research")).to be(false)
      expect(described_class.from_journal(journaled(deferral)).approved?("alpha", "research")).to be(false)
    end

    # The newest terminal verdict in the partition governs, so a denial of a
    # resubmitted draft withdraws the approval its first draft had.
    it "is false once a later denial in the partition follows an approval" do
      queue = described_class.from_journal(journaled(approval(digest: "blake3:v1"),
                                                     decision(policy: "signoff", approved: false, digest: "blake3:v2")))

      expect(queue.approved?("alpha", "research")).to be(false)
    end

    it "is true again once a re-approval follows that denial" do
      queue = described_class.from_journal(journaled(approval(digest: "blake3:v1"),
                                                     decision(policy: "signoff", approved: false, digest: "blake3:v2"),
                                                     approval(digest: "blake3:v3")))

      expect(queue.approved?("alpha", "research")).to be(true)
    end

    it "is unmoved by a deferral after an approval -- a deferral is no verdict" do
      queue = described_class.from_journal(journaled(approval(digest: "blake3:v1"), deferral(digest: "blake3:v2")))

      expect(queue.approved?("alpha", "research")).to be(true)
      expect(queue.drained?("alpha", "research")).to be(false)
    end

    it "keys on the whole partition: another epic, stage or issue vouches for nothing" do
      queue = described_class.from_journal(journaled(approval(epic_slug: "beta"),
                                                     approval(stage: "issue_plan", issue_id: "a")))

      expect(queue.approved?("alpha", "research")).to be(false)
      expect(queue.approved?("beta", "epic_plan")).to be(false)
      expect(queue.approved?("alpha", "issue_plan", issue_id: "b")).to be(false)
      expect(queue.approved?("alpha", "issue_plan", issue_id: "a")).to be(true)
    end

    it "reads a Symbol pair the same as its Strings" do
      expect(described_class.from_journal(journaled(approval)).approved?(:alpha, :research)).to be(true)
    end
  end

  # An issue's plan and its implementation are ONE issue's work, so a sign-off
  # parked for issue a must not hold issue b's gate shut. A question that names
  # no issue is answered for EVERY issue -- the conservative reading -- and an
  # item that names no issue (an epic-wide stage, or a record written before
  # issues were scoped) is seen by every issue's question for the same reason.
  describe "issue-scoped partitions" do
    def issue_park(queue, issue_id, digest: "blake3:#{issue_id}")
      park(queue, digest:, stage: "issue_plan", issue_id:)
    end

    def damaged_approval
      approval(stage: "issue_plan", issue_id: "a", digest: "blake3:a").to_journal.merge("approved" => [])
    end

    it "keeps one issue's parked sign-off out of a sibling's partition" do
      queue = described_class.new
      issue_park(queue, "a")

      expect(queue.drained?("alpha", "issue_plan", issue_id: "b")).to be(true)
      expect(queue.drained?("alpha", "issue_plan", issue_id: "a")).to be(false)
    end

    it "answers for every issue when the question names none" do
      queue = described_class.new
      issue_park(queue, "a")
      issue_park(queue, "b")

      expect(queue.drained?("alpha", "issue_plan")).to be(false)
      expect(queue.parked("alpha", "issue_plan").map(&:issue_id)).to eq(%w[a b])
    end

    it "narrows the review surface to one issue when asked" do
      queue = described_class.new
      issue_park(queue, "a")
      issue_park(queue, "b")

      expect(queue.parked("alpha", "issue_plan", issue_id: "b").map(&:artifact_digest)).to eq(["blake3:b"])
    end

    it "lets an item that names no issue hold every issue's question" do
      queue = described_class.new
      park(queue, stage: "issue_plan")

      expect(queue.drained?("alpha", "issue_plan", issue_id: "b")).to be(false)
    end

    it "folds an issue's deferral and drains it only by a decision for the same issue" do
      held = described_class.from_journal(journaled(deferral(stage: "issue_plan", issue_id: "a"),
                                                    approval(stage: "issue_plan", issue_id: "b")))
      answered = described_class.from_journal(journaled(deferral(stage: "issue_plan", issue_id: "a"),
                                                        approval(stage: "issue_plan", issue_id: "a")))

      expect(held.map(&:issue_id)).to eq(["a"])
      expect(answered.to_a).to be_empty
    end

    it "recovers the criteria digest the deferral carried" do
      queue = described_class.from_journal(journaled(deferral(stage: "issue_plan", issue_id: "a",
                                                              criteria_digest: "blake3:criteria")))

      expect(queue.first).to have_attributes(issue_id: "a", criteria_digest: "blake3:criteria")
    end

    it "refuses a blank issue id -- it would key a partition no issue can match" do
      expect { park(described_class.new, issue_id: " ") }.to raise_error(ArgumentError, /issue_id/)
    end

    # A damaged line: an issue id that is not text would stringify into an
    # issue nobody has, park where no issue's question looks, and read as
    # drained for every real issue. Refused before anything stringifies it.
    [[], ["a"], 7, { "a" => 1 }].each do |damaged|
      it "refuses a deferral whose issue_id is #{damaged.inspect}, rather than parking it out of sight" do
        line = deferral(stage: "issue_plan").to_journal.merge("issue_id" => damaged)

        expect { described_class.from_journal([line]) }.to raise_error(described_class::UnreadableRecord, /issue_id/)
      end
    end

    it "keeps #park's keywords explicit, so its signature says what an item carries" do
      expect(described_class.instance_method(:park).parameters.map(&:last))
        .to eq(%i[artifact_digest epic_slug stage issue_id question evidence_digest criteria_digest])
    end

    # Scenario: a damaged decision line cannot drain a parked sign-off
    it "refuses a live decision whose approved is [], leaving the issue's sign-off parked" do
      queue = described_class.new
      issue_park(queue, "a")

      expect { queue.apply(damaged_approval) }.to raise_error(ArgumentError, /approved/)
      expect(queue.drained?("alpha", "issue_plan", issue_id: "a")).to be(false)
    end

    it "refuses the whole rebuild over the same damaged line" do
      lines = journaled(deferral(stage: "issue_plan", issue_id: "a", digest: "blake3:a")) +
              ["#{JSON.generate(damaged_approval)}\n"]

      expect { described_class.from_journal(lines) }.to raise_error(described_class::UnreadableRecord, /approved/)
    end
  end

  describe Lain::Approval::SignoffQueue::Partition do
    it "is equal for the same pair, so it can key the fold" do
      expect(described_class.new(epic_slug: "alpha", stage: "research"))
        .to eq(described_class.new(epic_slug: :alpha, stage: :research))
    end

    it "tells two issues' partitions apart, and names the issue when it renders" do
      a = described_class.new(epic_slug: "alpha", stage: "issue_plan", issue_id: "a")

      expect(a).not_to eq(described_class.new(epic_slug: "alpha", stage: "issue_plan", issue_id: "b"))
      expect(a.to_s).to eq("alpha/issue_plan/a")
    end

    it "stays Ractor-shareable with an issue in it" do
      expect(described_class.new(epic_slug: +"alpha", stage: +"issue_plan", issue_id: +"a")).to be_deeply_frozen
    end

    it "is Ractor-shareable (two interned Strings)" do
      expect(described_class.new(epic_slug: +"alpha", stage: +"research")).to be_deeply_frozen
    end
  end

  describe Lain::Approval::SignoffQueue::Item do
    def item(**overrides)
      described_class.new(artifact_digest: "blake3:plan", epic_slug: "alpha", stage: "research", **overrides)
    end

    it "answers the partition it sits in" do
      expect(item.partition).to eq(Lain::Approval::SignoffQueue::Partition.new(epic_slug: "alpha",
                                                                               stage: "research"))
    end

    it "is Ractor-shareable with prose and evidence attached" do
      expect(item(question: +"Approve?", evidence_digest: +"blake3:spike")).to be_deeply_frozen
    end

    # Deep immutability cannot be conditional on what a caller happened to pass:
    # an arbitrary object with one mutable ivar would make the whole value
    # non-shareable, so every member is settled into frozen bytes here.
    it "stays shareable when handed a question that is not a String" do
      expect(item(question: Object.new)).to be_deeply_frozen
    end

    it "keeps every stored member frozen" do
      stored = item(question: +"Approve?", evidence_digest: +"blake3:spike")

      expect(stored.to_h.values).to all(be_frozen)
    end
  end
end
