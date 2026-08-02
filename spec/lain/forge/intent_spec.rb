# frozen_string_literal: true

# The forge tier's two journal records. They are Journalable Data values like
# every other Lain::Telemetry event, and their `type` strings are DURABLE
# journal discriminators a later reconcile joins on -- so both spellings are
# pinned here, including the `forge_` prefix that Journalable's class-name
# derivation would NOT have produced.
RSpec.describe Lain::Forge::Intent do
  def intent(**overrides)
    described_class.new(action: "promote", epic_slug: "demo", issue_id: "a1",
                        params: { "ref" => "refs/heads/epic/demo/a1", "sha" => "cafe" }, **overrides)
  end

  def journaled(*records)
    io = StringIO.new
    journal = Lain::Journal.new(io:)
    records.each { |record| journal.record(record) }
    io.string.lines
  end

  it "journals under a forge-prefixed discriminator, not the derived class name" do
    expect(intent.journal_type).to eq("forge_intent")
    expect(described_class::JOURNAL_TYPE).to eq("forge_intent")
  end

  it "round-trips through the journal, string-keyed, under its discriminator" do
    other = Lain::Forge::Outcome.new(intent_id: "x", ok: true)

    found = Lain::Journal.records(journaled(intent, other), type: "forge_intent").to_a

    expect(found.size).to eq(1)
    expect(found.first).to include("type" => "forge_intent", "action" => "promote", "epic_slug" => "demo",
                                   "issue_id" => "a1")
  end

  describe "the intent id" do
    it "is the digest of action plus params" do
      expect(intent.intent_id).to eq(described_class.id_for(action: "promote",
                                                            params: { "ref" => "refs/heads/epic/demo/a1",
                                                                      "sha" => "cafe" }))
      expect(intent.intent_id).to start_with("blake3:")
    end

    it "is equal for two intents naming the same action and params" do
      expect(intent.intent_id).to eq(intent.intent_id)
    end

    it "differs when the params differ" do
      expect(intent(params: { "ref" => "refs/heads/epic/demo/a1", "sha" => "beef" }).intent_id)
        .not_to eq(intent.intent_id)
    end

    # The card fixes the id at (action, params). Slug and issue live on the
    # record for reading, never in the address -- pinned so a later card cannot
    # widen the address without this spec saying so.
    it "ignores the epic and issue the intent is filed under" do
      expect(intent(epic_slug: "other", issue_id: "z9").intent_id).to eq(intent.intent_id)
    end

    # The obligation that omission creates, pinned in both directions. Every
    # action's params must address its effect uniquely repo-wide, because the
    # params ARE the whole address: real promote params carry
    # refs/heads/epic/<slug>/<issue>, and a pr_merge carries a repo-unique
    # number, so the epic and issue are already in there.
    it "distinguishes two issues whose params carry the namespaced ref" do
      other = intent(issue_id: "a2", params: { "ref" => "refs/heads/epic/demo/a2", "sha" => "cafe" })

      expect(other.intent_id).not_to eq(intent.intent_id)
    end

    it "collides when params do NOT address the issue, which is why they must" do
      alpha = intent(epic_slug: "alpha", issue_id: "one", params: { "ref" => "refs/heads/release", "sha" => "c" })
      beta = intent(epic_slug: "beta", issue_id: "two", params: { "ref" => "refs/heads/release", "sha" => "c" })

      expect(alpha.intent_id).to eq(beta.intent_id)
    end

    it "collapses Symbol and String param keys, as the wire form does" do
      expect(intent(params: { ref: "refs/heads/epic/demo/a1", sha: "cafe" }).intent_id).to eq(intent.intent_id)
    end
  end

  describe ".from_record" do
    it "carries the id that was WRITTEN, never a freshly derived one" do
      record = intent.to_journal.merge("intent_id" => "blake3:written-long-ago")

      expect(described_class.from_record(record).intent_id).to eq("blake3:written-long-ago")
    end

    it "rebuilds every member the fold reads" do
      rebuilt = described_class.from_record(Lain::Journal.parse(journaled(intent).first))

      expect(rebuilt.action).to eq("promote")
      expect(rebuilt.epic_slug).to eq("demo")
      expect(rebuilt.issue_id).to eq("a1")
      expect(rebuilt.params).to eq("ref" => "refs/heads/epic/demo/a1", "sha" => "cafe")
    end
  end

  it "refuses an action outside the closed set" do
    expect { intent(action: "push") }.to raise_error(ArgumentError, /action/)
    expect(Lain::Forge::ACTIONS).to eq(%w[promote pr_create pr_merge])
  end

  it "refuses an unnamed epic or an unnamed issue" do
    expect { intent(epic_slug: nil) }.to raise_error(ArgumentError, /epic_slug/)
    expect { intent(issue_id: "  ") }.to raise_error(ArgumentError, /issue_id/)
  end

  it "treats absent params as empty rather than nil" do
    expect(intent(action: "pr_merge", params: nil).params).to eq({})
  end

  it "is a deeply frozen, shareable value" do
    expect(Ractor.shareable?(intent)).to be(true)
  end
end

RSpec.describe Lain::Forge::Outcome do
  def outcome(**overrides)
    described_class.new(intent_id: "blake3:abc", ok: true, **overrides)
  end

  it "journals under a forge-prefixed discriminator" do
    expect(outcome.journal_type).to eq("forge_outcome")
    expect(described_class::JOURNAL_TYPE).to eq("forge_outcome")
  end

  it "carries its pairing key and verdict into the record" do
    expect(outcome(observed: true, detail: { "number" => 12 }).to_journal)
      .to eq("type" => "forge_outcome", "intent_id" => "blake3:abc", "ok" => true,
             "observed" => true, "detail" => { "number" => 12 })
  end

  # Null Object over nil: an outcome that carried nothing still answers #detail
  # with something a caller can read, so nothing downstream guards on nil.
  it "defaults to not-observed with an empty detail" do
    expect(outcome.observed).to be(false)
    expect(outcome.detail).to eq({})
  end

  it "answers its two booleans as predicates" do
    expect(outcome).to be_ok
    expect(outcome(observed: true)).to be_observed
    expect(outcome(ok: false)).not_to be_ok
  end

  it "refuses a non-boolean verdict and an unnamed intent" do
    expect { outcome(ok: "yes") }.to raise_error(ArgumentError, /ok/)
    expect { outcome(observed: nil) }.to raise_error(ArgumentError, /observed/)
    expect { outcome(intent_id: nil) }.to raise_error(ArgumentError, /intent_id/)
  end

  it "refuses an observed outcome that is not successful, including on replay" do
    expect { outcome(ok: false, observed: true) }.to raise_error(ArgumentError, /observed/)

    record = outcome.to_journal.merge("ok" => false, "observed" => true)
    expect { described_class.from_record(record) }.to raise_error(ArgumentError, /observed/)
  end

  it "rebuilds from a journal record" do
    rebuilt = described_class.from_record(outcome(detail: { "error" => "diverged" }).to_journal)

    expect(rebuilt).to eq(outcome(detail: { "error" => "diverged" }))
  end

  it "is a deeply frozen, shareable value" do
    expect(Ractor.shareable?(outcome(detail: { "pr" => { "number" => 3 } }))).to be(true)
  end
end
