# frozen_string_literal: true

RSpec.describe Lain::Epic::Signoff do
  verdicts = Lain::Approval::Verdict
  deferred = Lain::Epic::SignoffQueue::DEFERRED_POLICY
  parked = Lain::Epic::GateDecision::Deferred.new
  journaled = lambda do |verdict, digest: "blake3:d1", stage: "issue_plan", issue_id: "a", policy: "signoff"|
    Lain::Epic::GateDecision.new(artifact_digest: digest, epic_slug: "alpha", stage:, verdict:,
                                 answered_by: policy, policy:, latency: 0.1, issue_id:).to_journal
  end
  decided = ->(verdict, **address) { Lain::Telemetry::Untyped.new(fields: journaled.call(verdict, **address)) }
  issue_a = Lain::Epic::SignoffQueue::Partition.new(epic_slug: "alpha", stage: "issue_plan", issue_id: "a")
  research = Lain::Epic::SignoffQueue::Partition.new(epic_slug: "alpha", stage: "research")
  turn = Lain::Telemetry::Untyped.new(fields: { "type" => "turn", "digest" => "d1", "parent" => nil })
  message = Lain::Telemetry::Message.new(digest: "blake3:#{"5" * 64}", kind: :message, from: "parentchain", to: nil,
                                         payload: { "text" => "a note" }, causal_parents: [], correlation: nil)

  palette = [decided.call(verdicts::Approve.new), decided.call(verdicts::Deny.new(note: "too broad")),
             decided.call(verdicts::Approve.new, digest: "blake3:d2"), decided.call(verdicts::Hold.new),
             decided.call(parked, policy: deferred),
             decided.call(parked, digest: "blake3:d2", policy: deferred),
             decided.call(verdicts::Approve.new, stage: "research", issue_id: nil, digest: "blake3:r1"), turn,
             message]
  g = PropCheck::Generators
  record_lists = g.array(g.one_of(*palette.map { g.constant(_1) }), min: 0, max: 5)

  # Every shape the sign-off queue tells apart, over 2 partitions and 2 drafts, so a superseded
  # draft, a re-deferral and a hold over an answered address turn up within the runs.
  digests = %w[blake3:v1 blake3:v2]
  partitions = [research, issue_a]
  shapes = [verdicts::Approve.new, verdicts::Deny.new, verdicts::Hold.new].map { [_1, "signoff"] } +
           [[parked, deferred], [verdicts::Hold.new, deferred]]
  any_decision = g.tuple(g.one_of(*shapes.map { g.constant(_1) }), g.one_of(*digests.map { g.constant(_1) }),
                         g.one_of(*partitions.map { g.constant(_1) }))
                  .map do |(verdict, policy), digest, partition|
    decided.call(verdict, digest:, policy:, stage: partition.stage, issue_id: partition.issue_id)
  end
  sessions = g.array(g.one_of(*[any_decision] * 4, g.constant(turn)), min: 0, max: 14)

  describe "#held_items" do
    it "names each held draft with its partition, and none once it is answered" do
      held = described_class.over([decided.call(verdicts::Hold.new(note: "later"), digest: "blake3:h1")])
      answered = held.step(decided.call(verdicts::Approve.new, digest: "blake3:h1"))

      expect(held.held_items.map { [_1.partition, _1.artifact_digest] }).to eq([[issue_a, "blake3:h1"]])
      expect(answered.held_items).to be_empty
    end
  end

  describe "the laws" do
    include_examples "an incremental fold", projection: described_class, generator: record_lists, samples: 8

    it "combines any 3 cuts of a session associatively, with the unit on either side", aggregate_failures: false do
      forall(session: sessions, cuts: g.tuple(g.nonnegative_integer, g.nonnegative_integer)) do |session:, cuts:|
        i, j = cuts.map { _1 % (session.size + 1) }.sort
        a, b, c = [session[0...i], session[i...j], session[j..]].map { described_class.over(_1) }

        expect(a.combine(b).combine(c)).to eq(a.combine(b.combine(c)))
        expect([described_class.unit.combine(a), a.combine(described_class.unit)]).to eq([a, a])
        expect(a.combine(b).combine(c)).to eq(described_class.over(session))
      end
    end

    it "reads the same parked drafts and holds from any 3 cuts combined as from the whole session",
       aggregate_failures: false do
      forall(session: sessions, cuts: g.tuple(g.nonnegative_integer, g.nonnegative_integer)) do |session:, cuts:|
        i, j = cuts.map { _1 % (session.size + 1) }.sort
        a, b, c = [session[0...i], session[i...j], session[j..]].map { described_class.over(_1) }
        whole = described_class.over(session)

        views = [a.combine(b).combine(c), a.combine(b.combine(c)), whole].map do |signoff|
          partitions.map { signoff.view(_1, current: digests.first) }.map { [_1.drafts, _1.held] }
        end
        expect(views.uniq.size).to eq(1)
      end
    end
  end

  it "answers what the sign-off queue answers for every partition and draft", aggregate_failures: false do
    forall(session: sessions) do |session:|
      signoff = described_class.over(session)
      queue = Lain::Epic::SignoffQueue.from_journal(session.map(&:fields))

      answers = partitions.product(digests).map do |partition, digest|
        [signoff.approved?(partition, digest),
         queue.standing?(digest, partition.epic_slug, partition.stage, issue_id: partition.issue_id)]
      end
      expect(answers.map(&:first)).to eq(answers.map(&:last))
    end
  end

  it "parks and holds what the sign-off queue parks and holds for every partition", aggregate_failures: false do
    forall(session: sessions) do |session:|
      signoff = described_class.over(session)
      queue = Lain::Epic::SignoffQueue.from_journal(session.map(&:fields))

      listed = partitions.map do |partition|
        asked = [partition.epic_slug, partition.stage]
        [queue.parked(*asked, issue_id: partition.issue_id).map(&:artifact_digest),
         queue.held(*asked, issue_id: partition.issue_id).map(&:artifact_digest)]
      end
      expect(partitions.map { signoff.view(_1, current: nil).then { |view| [view.drafts, view.held] } }).to eq(listed)
    end
  end

  it "answers the newest decision of a partition" do
    signoff = described_class.over([decided.call(verdicts::Approve.new), decided.call(verdicts::Deny.new)])

    expect(signoff.standing(issue_a)).to eq(described_class::Standing.new(digest: "blake3:d1",
                                                                          verdict: verdicts::Deny.new))
    expect(signoff.approved?(issue_a, "blake3:d1")).to be(false)
  end

  it "keeps a newer approval standing when a draft it superseded is denied" do
    signoff = described_class.over([decided.call(parked, digest: "blake3:v1", policy: deferred),
                                    decided.call(verdicts::Approve.new, digest: "blake3:v2"),
                                    decided.call(verdicts::Deny.new, digest: "blake3:v1")])

    expect(signoff.standing(issue_a)).to eq(described_class::Standing.new(digest: "blake3:v2",
                                                                          verdict: verdicts::Approve.new))
  end

  it "withdraws the approval when a superseded draft is deferred again and then denied" do
    signoff = described_class.over([decided.call(parked, digest: "blake3:v1", policy: deferred),
                                    decided.call(verdicts::Approve.new, digest: "blake3:v2"),
                                    decided.call(parked, digest: "blake3:v1", policy: deferred),
                                    decided.call(verdicts::Deny.new, digest: "blake3:v1")])

    expect(signoff.approved?(issue_a, "blake3:v2")).to be(false)
  end

  it "withdraws the approval when a re-approved draft is denied, as the sign-off queue does" do
    session = [decided.call(parked, digest: "blake3:v2", policy: deferred),
               decided.call(verdicts::Approve.new, digest: "blake3:v3"),
               decided.call(verdicts::Approve.new, digest: "blake3:v2"),
               decided.call(verdicts::Deny.new, digest: "blake3:v2")]
    queue = Lain::Epic::SignoffQueue.from_journal(session.map(&:fields))

    expect([described_class.over(session).approved?(issue_a, "blake3:v2"),
            queue.standing?("blake3:v2", "alpha", "issue_plan", issue_id: "a")]).to eq([false, false])
  end

  it "withdraws a later approval when a draft already denied out of the queue is denied again" do
    session = [decided.call(parked, digest: "blake3:v1", policy: deferred),
               decided.call(verdicts::Deny.new, digest: "blake3:v1"),
               decided.call(verdicts::Approve.new, digest: "blake3:v2"),
               decided.call(verdicts::Deny.new, digest: "blake3:v1")]
    queue = Lain::Epic::SignoffQueue.from_journal(session.map(&:fields))

    expect([described_class.over(session).approved?(issue_a, "blake3:v2"),
            queue.standing?("blake3:v2", "alpha", "issue_plan", issue_id: "a")]).to eq([false, false])
  end

  it "keeps that approval when the halves are folded apart and combined" do
    left = described_class.over([decided.call(parked, digest: "blake3:v1", policy: deferred),
                                 decided.call(verdicts::Approve.new, digest: "blake3:v2")])
    right = described_class.over([decided.call(verdicts::Deny.new, digest: "blake3:v1")])

    expect(left.combine(right).approved?(issue_a, "blake3:v2")).to be(true)
  end

  it "approves only the digest that was approved, asked by its text" do
    signoff = described_class.over([decided.call(verdicts::Approve.new, stage: "research", issue_id: nil,
                                                                        digest: "blake3:r1")])

    expect([signoff.approved?(research, "blake3:r2"), signoff.approved?(research, :"blake3:r1")]).to eq([false, true])
  end

  it "answers nothing for a partition no decision named" do
    expect(described_class.over([decided.call(verdicts::Approve.new)]).standing(research)).to be_nil
  end

  it "leaves a standing approval standing through a hold or a deferral of it" do
    approved = described_class.over([decided.call(verdicts::Approve.new)])
    later = [decided.call(verdicts::Hold.new), decided.call(parked, policy: deferred)]

    expect(approved.over(later).approved?(issue_a, "blake3:d1")).to be(true)
  end

  describe "a deferred record" do
    raw = lambda { |verdict, digest:, policy:|
      journaled.call(verdicts::Deny.new, digest:, policy:).merge("verdict" => verdict)
    }

    it "parks by its verdict whatever its policy says, so a superseded draft's later deny leaves the approval" do
      session = [raw.call("deferred", digest: "blake3:v1", policy: "signoff"),
                 journaled.call(verdicts::Approve.new, digest: "blake3:v2"),
                 journaled.call(verdicts::Deny.new, digest: "blake3:v1")]

      expect(described_class.from_journal(session).approved?(issue_a, "blake3:v2")).to be(true)
    end

    it "settles a deny journaled under the deferred policy, because no reader compares the policy string" do
      session = [raw.call("deny", digest: "blake3:v1", policy: deferred)]

      expect(described_class.from_journal(session).standing(issue_a))
        .to eq(described_class::Standing.new(digest: "blake3:v1", verdict: verdicts::Deny.new))
    end
  end

  it "answers itself for a typed record that is not a gate decision" do
    signoff = described_class.over([decided.call(verdicts::Approve.new)])

    expect(signoff.step(message)).to be(signoff)
  end

  it "keeps the verdict's note" do
    signoff = described_class.over([decided.call(verdicts::Deny.new(note: "too broad"))])

    expect(signoff.standing(issue_a).verdict.note).to eq("too broad")
  end

  describe "reading a journal" do
    it "folds journal lines and records as it folds the records read from them" do
      lines = [journaled.call(verdicts::Approve.new), turn.fields, journaled.call(verdicts::Deny.new)]

      expect(described_class.from_journal(lines.map { JSON.generate(_1) }))
        .to eq(described_class.over([decided.call(verdicts::Approve.new), turn,
                                     decided.call(verdicts::Deny.new)]))
      expect(described_class.from_journal(lines).approved?(issue_a, "blake3:d1")).to be(false)
    end

    it "folds a gate decision handed over as a value as it folds its journaled form" do
      value = Lain::Epic::GateDecision.new(artifact_digest: "blake3:d1", epic_slug: "alpha", stage: "issue_plan",
                                           verdict: verdicts::Approve.new, answered_by: "signoff",
                                           policy: "signoff", latency: 0.1, issue_id: "a")

      expect(described_class.over([value]))
        .to eq(described_class.over([Lain::Telemetry::Untyped.new(fields: value.to_journal)]))
      expect(described_class.over([value]).approved?(issue_a, "blake3:d1")).to be(true)
    end

    it "refuses to step a Hash or a line, which are not records" do
      expect { described_class.unit.step(journaled.call(verdicts::Approve.new)) }.to raise_error(TypeError, /Hash/)
      expect { described_class.unit.step("{}") }.to raise_error(TypeError, /String/)
    end
  end

  describe "refusing a damaged gate_decision" do
    def refusal(fields)
      described_class.over([Lain::Telemetry::Untyped.new(fields:)])
    rescue Lain::Epic::SignoffQueue::UnreadableRecord => e
      e.message
    end

    it "names the record and the verdict it lacks" do
      expect(refusal(journaled.call(verdicts::Approve.new).except("verdict")))
        .to match(%r{blake3:d1.*alpha/issue_plan/a.*verdict})
    end

    it "refuses a policy outside the closed set, which the fold branches on" do
      expect(refusal(journaled.call(verdicts::Approve.new).merge("policy" => "defered"))).to include("policy")
    end

    it "refuses a stage off the pipeline" do
      expect(refusal(journaled.call(verdicts::Approve.new).merge("stage" => "review"))).to include("stage")
    end

    it "refuses an empty digest" do
      expect(refusal(journaled.call(verdicts::Approve.new).merge("artifact_digest" => "")))
        .to include("artifact_digest")
    end
  end
end
