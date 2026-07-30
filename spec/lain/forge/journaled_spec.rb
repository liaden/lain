# frozen_string_literal: true

# Forge::Journaled is the intent-before-effect bracket around either executor.
# The ordering IS the design: a forge action pushes a ref or merges a pull
# request -- effects no local file can be re-read to discover -- so the record
# has to exist BEFORE the attempt, and an intent with no outcome is precisely the
# shape of a crash for Forge::Reconcile to read back.
#
# This is the OPPOSITE of Epic::Home::Journaled, where doc_written is an ack
# written after a successful local write. Both are deliberate; the examples below
# pin this one so nobody harmonises them.
RSpec.describe Lain::Forge::Journaled do
  subject(:journaled) do
    described_class.new(live, journal:, epic_slug: GhParity::EPIC_SLUG, issue_id: GhParity::ISSUE_ID)
  end

  let(:io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io:) }
  let(:factory) { GhParity.factory }
  let(:live) { Lain::Forge::Gh.new(shell_out_factory: factory) }

  # The `world` duck Reconcile asks, in the only shape these examples need.
  world_class = Struct.new(:state) do
    def pr_state(_number) = state
  end

  # An executor that looks at the journal WHILE it is being called -- the only
  # way to observe that the intent was written before the effect ran, as opposed
  # to merely written earlier in the same method.
  peeking_class = Struct.new(:peek) do
    def pr_merge(**)
      peek.call
      Lain::Forge::Gh::Answer.new(ok: true)
    end
  end

  def records = Lain::Journal.records(io.string.lines).to_a

  # A decorator is only a decorator if it is substitutable for what it wraps.
  it_behaves_like "a gh executor" do
    let(:executor) { journaled }
  end

  describe "the ordering" do
    # Not "the records come out in this order" -- that a crash could still
    # produce. The claim is that the intent is ON THE JOURNAL by the time the
    # subprocess runs, which is the only version of it a resume can rely on, so
    # the executor is what looks.
    it "has journaled the intent by the time the effect runs" do
      seen = nil
      peeking = peeking_class.new(-> { seen = records })

      described_class.new(peeking, journal:, epic_slug: "demo", issue_id: "a1").pr_merge(number: 7)

      expect(seen.map { |record| record["type"] }).to eq(%w[forge_intent])
    end

    it "journals the intent before the effect, then the outcome after it" do
      journaled.pr_create(base: GhParity::BASE, head: GhParity::HEAD,
                          title: GhParity::TITLE, body: GhParity::BODY)

      expect(records.map { |record| record["type"] }).to eq(%w[forge_intent forge_outcome])
    end

    # The one case where a crash is still legible from inside the process: the
    # outcome is journaled as not-ok and the exception continues, so a caller
    # sees the failure and the record shows an attempt that was made and failed.
    it "holds the intent and a not-ok outcome when the subprocess raises" do
      exploding = Lain::Forge::Gh.new(shell_out_factory: GhParity::FakeGh.new { raise Errno::ENOENT, "gh" })
      wrapped = described_class.new(exploding, journal:, epic_slug: "demo", issue_id: "a1")

      expect { wrapped.pr_merge(number: 7) }.to raise_error(Errno::ENOENT)

      intent, outcome = records
      expect(intent["type"]).to eq("forge_intent")
      expect(outcome).to include("type" => "forge_outcome", "ok" => false)
      expect(outcome["detail"]["error"]).to include("Errno::ENOENT")
    end

    it "journals the intent even when the executor cannot answer the verb at all" do
      wrapped = described_class.new(Object.new, journal:, epic_slug: "demo", issue_id: "a1")

      expect { wrapped.pr_merge(number: 7) }.to raise_error(NoMethodError)
      expect(records.first["type"]).to eq("forge_intent")
    end
  end

  describe "what the records say" do
    before do
      journaled.pr_create(base: GhParity::BASE, head: GhParity::HEAD,
                          title: GhParity::TITLE, body: GhParity::BODY)
    end

    # The address is the params and nothing else (Forge::Intent.id_for). It is
    # (head, base) because that is GitHub's own uniqueness key for an open pull
    # request -- head alone would hold only by the convention that base is always
    # main. The title and body stay out: they are the effect's CONTENT, and
    # journaling them would make a retry with a corrected title read as different
    # work and cost the fold its repeat.
    it "addresses a pr_create by the (head, base) pair GitHub itself keys on" do
      expect(records.first).to include("action" => "pr_create",
                                       "params" => { "head" => GhParity::HEAD, "base" => GhParity::BASE },
                                       "epic_slug" => GhParity::EPIC_SLUG, "issue_id" => GhParity::ISSUE_ID)
    end

    # The two spellings of the address live in different files (Journaled writes
    # it, Recorded looks it up) and a drift between them replays nothing at all,
    # silently. So the join is asserted rather than trusted.
    it "writes the intent_id a Recorded executor will look the outcome up by" do
      expect(records.first["intent_id"])
        .to eq(Lain::Forge::Intent.id_for(action: Lain::Forge::PR_CREATE,
                                          params: { "head" => GhParity::HEAD, "base" => GhParity::BASE }))
    end

    # Forge::Outcome carries only a digest, so an ORPHANED outcome could not
    # otherwise be traced to anybody's problem. The convention is that producers
    # put both in `detail`; this is the producer.
    it "attributes the outcome to its epic and issue, which the wire shape cannot carry" do
      expect(records.last["detail"]).to include("epic_slug" => GhParity::EPIC_SLUG,
                                                "issue_id" => GhParity::ISSUE_ID)
    end

    it "answers the intent it journaled, so the pair joins" do
      intent, outcome = records
      expect(outcome["intent_id"]).to eq(intent["intent_id"])
    end
  end

  describe "what is not an effect" do
    it "journals nothing for an observation -- asking is not doing" do
      journaled.merge_state(number: 7)
      journaled.pr_view(ref: "7", fields: %w[number])

      expect(records).to be_empty
    end
  end

  # The bracket is public because a producer of any closed action needs it: a
  # promotion is a git push rather than a gh verb, and it owes the same pair.
  describe "#attempt" do
    it "brackets any closed action a caller performs itself" do
      answer = journaled.attempt(action: Lain::Forge::PROMOTE,
                                 params: { "ref" => "refs/heads/epic/demo/a1", "sha" => "abc123" }) do
        Lain::Forge::Gh::Answer.new(ok: true, detail: { "value" => "abc123" })
      end

      expect(answer).to be_ok
      expect(records.map { |record| record["type"] }).to eq(%w[forge_intent forge_outcome])
      expect(records.first["action"]).to eq("promote")
    end

    it "refuses an action outside the closed set before anything is journaled" do
      expect { journaled.attempt(action: "rm_rf", params: {}) { nil } }.to raise_error(ArgumentError, /action/)
      expect(records).to be_empty
    end
  end

  # The whole point of the pair: Reconcile reads it back and says what landed.
  describe "read back through Reconcile" do
    it "reports a completed run as settled, with nothing outstanding" do
      journaled.pr_create(base: GhParity::BASE, head: GhParity::HEAD,
                          title: GhParity::TITLE, body: GhParity::BODY)
      journaled.pr_merge(number: GhParity::NUMBER)

      reconcile = Lain::Forge::Reconcile.new(entries: io.string.lines, world: world_class.new("OPEN"))

      expect(reconcile.settled.size).to eq(2)
      expect(reconcile.outstanding).to be_empty
      expect(reconcile.orphans).to be_empty
    end

    # A kill between the effect and its ack leaves the intent alone on the line,
    # which is exactly what the ordering exists to guarantee.
    it "leaves an intent outstanding when the process dies before the outcome" do
      journaled.pr_merge(number: GhParity::NUMBER)
      killed = io.string.lines.reject { |line| line.include?("forge_outcome") }

      reconcile = Lain::Forge::Reconcile.new(entries: killed, world: world_class.new("OPEN"))

      expect(reconcile.outstanding.size).to eq(1)
      expect(reconcile.outstanding.first).to be_needs_retry
    end

    it "reports the same intent as completed externally once the world says merged" do
      journaled.pr_merge(number: GhParity::NUMBER)
      killed = io.string.lines.reject { |line| line.include?("forge_outcome") }

      reconcile = Lain::Forge::Reconcile.new(entries: killed, world: world_class.new("MERGED"))

      expect(reconcile.outstanding.first).to be_completed_externally
    end
  end
end
