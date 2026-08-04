# frozen_string_literal: true

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module ForgeReconcileSpecSupport
  REF = "refs/heads/epic/demo/a1"

  # The `world` duck Reconcile observes through: a fixed table of remote refs,
  # PR states by number, and PRs by head ref. Fixed on purpose -- the fold's
  # idempotency claim is "same entries, same world, same report", and a world
  # that answered from a script would make the second run mean something else.
  World = Struct.new(:refs, :states, :heads, keyword_init: true) do
    def ref_exists?(ref) = refs.key?(ref)

    def sha_of(ref) = refs[ref]

    def pr_state(number) = states[number]

    def pr_for(head:) = heads[head]
  end

  def self.world(refs: {}, states: {}, heads: {}) = World.new(refs:, states:, heads:)

  # The same world, counting what it was asked. Against T24's real `gh` each of
  # these is a subprocess, so "how many times" is a question with a bill
  # attached -- and a repeated question against shared mutable remote state is
  # also how one report can contradict itself.
  class Counting < World
    def calls = (@calls ||= [])

    def ref_exists?(ref)
      calls << [:ref_exists?, ref]
      super
    end

    def sha_of(ref)
      calls << [:sha_of, ref]
      super
    end

    def pr_state(number)
      calls << [:pr_state, number]
      super
    end

    def pr_for(head:)
      calls << [:pr_for, head]
      super
    end
  end

  def self.counting(refs: {}, states: {}, heads: {}) = Counting.new(refs:, states:, heads:)
end

RSpec.describe Lain::Forge::Reconcile do
  let(:ref) { ForgeReconcileSpecSupport::REF }
  let(:nothing_happened) { ForgeReconcileSpecSupport.world }

  def promote(sha: "cafe")
    Lain::Forge::Intent.new(action: "promote", epic_slug: "demo", issue_id: "a1",
                            params: { "ref" => ForgeReconcileSpecSupport::REF, "sha" => sha })
  end

  def pr_create(head: ForgeReconcileSpecSupport::REF)
    Lain::Forge::Intent.new(action: "pr_create", epic_slug: "demo", issue_id: "a1",
                            params: { "base" => "main", "head" => head })
  end

  def pr_merge(number: 12)
    Lain::Forge::Intent.new(action: "pr_merge", epic_slug: "demo", issue_id: "a1",
                            params: { "number" => number, "auto" => false })
  end

  def settled_by(intent, **overrides)
    Lain::Forge::Outcome.new(intent_id: intent.intent_id, ok: true, **overrides)
  end

  def reconcile(records, world: ForgeReconcileSpecSupport.world)
    described_class.new(entries: records.map(&:to_journal), world:)
  end

  # AC1
  it "lists an intent with no outcome as unsettled" do
    fold = reconcile([promote])

    expect(fold.unsettled.map { |item| item.intent.action }).to eq(["promote"])
    expect(fold.settled).to be_empty
  end

  it "pairs an intent with the outcome that answers it" do
    intent = promote
    fold = reconcile([intent, settled_by(intent)])

    expect(fold.settled.map(&:intent)).to eq([intent])
    expect(fold.settled.first.outcome.intent_id).to eq(intent.intent_id)
    expect(fold.unsettled).to be_empty
  end

  # AC2 -- the crashed push. Promotion IS the push; there is no push action.
  it "marks an unsettled promote completed_externally when the ref stands at the pushed sha" do
    world = ForgeReconcileSpecSupport.world(refs: { ref => "cafe" })

    verdict = reconcile([promote], world:).unsettled.first

    expect(verdict).to be_completed_externally
    expect(verdict.verdict).to eq("completed_externally")
  end

  # AC3
  it "marks an unsettled promote needs_retry when the ref is absent" do
    expect(reconcile([promote], world: nothing_happened).unsettled.first).to be_needs_retry
  end

  it "marks an unsettled promote needs_retry when the ref stands at another sha" do
    world = ForgeReconcileSpecSupport.world(refs: { ref => "beef" })

    expect(reconcile([promote], world:).unsettled.first).to be_needs_retry
  end

  # AC4 -- identical action plus params means an identical id, so the pairing
  # has to be positional or the second attempt would read as already answered.
  it "pairs repeated identical intents positionally" do
    first = promote
    second = promote
    fold = reconcile([first, second, settled_by(first)])

    expect(fold.settled.size).to eq(1)
    expect(fold.unsettled.size).to eq(1)
    expect(fold.unsettled.first.intent).to eq(second)
  end

  # AC5
  it "names an outcome with no unmatched intent as an orphan, and never drops it" do
    intent = promote
    orphan = settled_by(intent, detail: { "note" => "second ack" })
    fold = reconcile([intent, settled_by(intent), orphan])

    expect(fold.orphans).to eq([orphan])
    expect(fold.settled.size).to eq(1)
    expect(fold.unsettled).to be_empty
  end

  it "names an outcome that answers nothing at all as an orphan" do
    stray = Lain::Forge::Outcome.new(intent_id: "blake3:nobody", ok: false)

    expect(reconcile([stray]).orphans).to eq([stray])
  end

  # AC6
  it "is idempotent: the same entries and the same world yield equal reports" do
    world = ForgeReconcileSpecSupport.world(refs: { ref => "cafe" }, states: { 12 => "MERGED" })
    intent = promote
    records = [intent, settled_by(intent), promote, pr_create, pr_merge,
               Lain::Forge::Outcome.new(intent_id: "blake3:nobody", ok: false)]

    expect(reconcile(records, world:).report).to eq(reconcile(records, world:).report)
  end

  # AC7 -- a pr_create that crashed has no PR number to look up, so the head ref
  # is the only address the world can be asked about.
  it "marks an unsettled pr_create completed_externally when the world reports a PR for its head" do
    world = ForgeReconcileSpecSupport.world(heads: { ref => { "number" => 12, "state" => "OPEN" } })

    expect(reconcile([pr_create], world:).unsettled.first).to be_completed_externally
  end

  it "marks an unsettled pr_create needs_retry when no PR names its head" do
    expect(reconcile([pr_create], world: nothing_happened).unsettled.first).to be_needs_retry
  end

  it "marks an unsettled pr_merge completed_externally only once the PR reads merged" do
    merged = ForgeReconcileSpecSupport.world(states: { 12 => "MERGED" })
    open = ForgeReconcileSpecSupport.world(states: { 12 => "OPEN" })

    expect(reconcile([pr_merge], world: merged).unsettled.first).to be_completed_externally
    expect(reconcile([pr_merge], world: open).unsettled.first).to be_needs_retry
  end

  describe "the walk itself" do
    it "reads raw NDJSON lines as readily as parsed records" do
      io = StringIO.new
      journal = Lain::Journal.new(io:)
      intent = promote
      [intent, settled_by(intent), pr_create].each { |record| journal.record(record) }

      fold = described_class.new(entries: io.string.lines, world: nothing_happened)

      expect(fold.settled.size).to eq(1)
      expect(fold.unsettled.map { |item| item.intent.action }).to eq(["pr_create"])
    end

    it "skips records belonging to other tiers" do
      other = Lain::Epic::IssueTransition.new(epic_slug: "demo", issue_id: "a1",
                                              from_status: "pending", to_status: "in_flight")

      expect(reconcile([other, promote]).unsettled.size).to eq(1)
    end

    # Epic::Progress's doctrine: a record that cannot be read whole aborts the
    # fold. Skipping a malformed forge_intent would lose exactly the intent
    # nobody would then retry -- the loss this fold exists to prevent.
    it "refuses a malformed intent record rather than skipping it" do
      broken = promote.to_journal.merge("action" => "push")

      expect { described_class.new(entries: [broken], world: nothing_happened) }
        .to raise_error(ArgumentError, /action/)
    end

    it "orders settled by the position of the INTENT in the journal, not the outcome" do
      first = promote
      second = pr_create
      fold = reconcile([first, second, settled_by(second), settled_by(first)])

      expect(fold.settled.map { |item| item.intent.action }).to eq(%w[promote pr_create])
    end

    it "does not write to its own index while reading it" do
      stray = Lain::Forge::Outcome.new(intent_id: "blake3:nobody", ok: false)

      expect(reconcile([stray]).unsettled).to be_empty
    end
  end

  # P14, P15, P16, P21, P22, P24 -- the observation phase, after the fix round.
  describe "an intent whose params cannot address the effect" do
    def blind(action: "promote", params: { "ref" => ForgeReconcileSpecSupport::REF })
      Lain::Forge::Intent.new(action:, epic_slug: "demo", issue_id: "a1", params:)
    end

    it "is named in its own list rather than raising" do
      fold = reconcile([blind])

      expect(fold.unaddressable.map(&:intent)).to eq([blind])
      expect(fold.unaddressable.first.reason).to match(/promote.*"sha"/m)
      expect(fold.unsettled).to be_empty
    end

    # P21/P22: the `&&` short-circuited past the second address, so the same
    # malformed record was a hard error or a quiet needs_retry according to what
    # GitHub happened to hold.
    it "reads the same whether or not the world would have answered" do
      absent = reconcile([blind], world: ForgeReconcileSpecSupport.world)
      present = reconcile([blind], world: ForgeReconcileSpecSupport.world(refs: { ref => "cafe" }))

      expect(absent.unaddressable.size).to eq(1)
      expect(present.unaddressable.size).to eq(1)
    end

    it "never consults the world at all" do
      world = ForgeReconcileSpecSupport.counting(refs: { ref => "cafe" })
      reconcile([blind], world:)

      expect(world.calls).to be_empty
    end

    # P24: `fetch` succeeds on a nil, and two `.to_s` calls then read two
    # ABSENCES of knowledge as a confirmation that the push landed.
    it "refuses a blank address as hard as a missing one" do
      world = ForgeReconcileSpecSupport.world(refs: { ref => nil })
      nilled = blind(params: { "ref" => ref, "sha" => nil })

      expect(reconcile([nilled], world:).unaddressable.size).to eq(1)
      expect(reconcile([nilled], world:).unsettled).to be_empty
    end

    # P24 one type over. `false.to_s` is "false", a perfectly good String, so
    # the blank rule alone let a boolean through -- and `Canonical.normalize`
    # preserves booleans happily, so nothing upstream filters them.
    it "refuses a boolean address, which is not an address at all" do
      world = ForgeReconcileSpecSupport.world(refs: { ref => false })

      expect(reconcile([blind(params: { "ref" => ref, "sha" => false })], world:).unaddressable.size).to eq(1)
      expect(reconcile([blind(params: { "ref" => ref, "sha" => true })], world:).unaddressable.size).to eq(1)
      expect(reconcile([blind(action: "pr_merge", params: { "number" => false })]).unaddressable.size).to eq(1)
    end

    it "accepts a number as readily as a String, because a PR number is one" do
      world = ForgeReconcileSpecSupport.world(states: { 12 => "MERGED" })

      expect(reconcile([blind(action: "pr_merge", params: { "number" => 12 })], world:).unaddressable).to be_empty
    end

    # P16: at 3am, one malformed line must not cost the operator sight of what
    # actually landed.
    it "costs the report nothing else -- settled pairs and orphans survive it" do
      intent = promote
      stray = Lain::Forge::Outcome.new(intent_id: "blake3:nobody", ok: false)
      fold = reconcile([intent, settled_by(intent), blind, stray])

      expect(fold.settled.size).to eq(1)
      expect(fold.orphans).to eq([stray])
      expect(fold.unaddressable.size).to eq(1)
    end
  end

  # P9, P10, P11 -- each world question is a subprocess against shared mutable
  # remote state, so asking one question twice is both a bill and a way for one
  # report to contradict itself.
  describe "asking the world" do
    it "asks once per intent_id, however many times the action repeats" do
      world = ForgeReconcileSpecSupport.counting
      reconcile([promote, promote, promote], world:)

      expect(world.calls).to eq([[:ref_exists?, ref]])
    end

    it "gives every repeat of one id the same verdict" do
      verdicts = reconcile([promote, promote], world: ForgeReconcileSpecSupport.counting).unsettled

      expect(verdicts.map(&:verdict).uniq.size).to eq(1)
    end

    it "still asks separately for two different ids" do
      world = ForgeReconcileSpecSupport.counting
      reconcile([promote, pr_create], world:)

      expect(world.calls).to eq([[:ref_exists?, ref], [:pr_for, ref]])
    end

    # The memo may NOT key on intent_id. `Intent.from_record` keeps the STORED
    # id (correctly -- the pairing joins on it), so on the read path an id is
    # whatever the journal says, not a fact about the question. A damaged or
    # hand-written line naming one id for two different actions would otherwise
    # answer both with the first one's verdict.
    context "with two records sharing a stored id but naming different actions" do
      let(:world) { ForgeReconcileSpecSupport.counting(refs: { ref => "cafe" }, states: { 12 => "OPEN" }) }

      def forged
        Lain::Forge::Intent.new(action: "pr_merge", epic_slug: "demo", issue_id: "a1",
                                params: { "number" => 12, "auto" => false },
                                intent_id: promote.intent_id)
      end

      it "asks the question each record actually poses" do
        reconcile([promote, forged], world:)

        expect(world.calls).to eq([[:ref_exists?, ref], [:sha_of, ref], [:pr_state, 12]])
      end

      it "does not report an OPEN pull request as already merged" do
        verdicts = reconcile([promote, forged], world:).unsettled

        expect(verdicts.map { |item| [item.intent.action, item.verdict] })
          .to eq([%w[promote completed_externally], %w[pr_merge needs_retry]])
      end
    end
  end

  # P2: both halves of a settled pair present in the file, reported as two
  # unrelated facts.
  describe "#misordered" do
    it "names an intent_id that is both unsettled and orphaned" do
      intent = promote
      fold = reconcile([settled_by(intent), intent])

      expect(fold.misordered).to eq([intent.intent_id])
    end

    it "is empty for a journal whose intents all precede their outcomes" do
      intent = promote

      expect(reconcile([intent, settled_by(intent), pr_create]).misordered).to be_empty
    end

    # Fixes 4 and 6 landed in the same round and did not meet: #misordered was
    # written against three lists while a fourth was being added, so the same
    # corruption went unflagged the moment the intent was also unaddressable.
    it "names an unaddressable intent that is also orphaned" do
      blind = Lain::Forge::Intent.new(action: "promote", epic_slug: "demo", issue_id: "a1",
                                      params: { "ref" => ref })
      fold = reconcile([settled_by(blind), blind])

      expect(fold.orphans.size).to eq(1)
      expect(fold.unaddressable.size).to eq(1)
      expect(fold.misordered).to eq([blind.intent_id])
    end
  end

  # The four lists are TWO partitions, not one four-way split, and a caller
  # asking "what is still outstanding" should not have to union them by hand.
  describe "#outstanding" do
    it "is every intent with no outcome, judged or not" do
      blind = Lain::Forge::Intent.new(action: "promote", epic_slug: "demo", issue_id: "a1",
                                      params: { "ref" => ref })
      fold = reconcile([promote, blind])

      expect(fold.outstanding.map { |item| item.intent.action }).to eq(%w[promote promote])
      expect(fold.outstanding).to eq(fold.unsettled + fold.unaddressable)
    end

    it "is empty when every intent was answered" do
      intent = promote

      expect(reconcile([intent, settled_by(intent)]).outstanding).to be_empty
    end
  end

  # P23: the constants' own comment rejects StringInquirer because a typo must
  # not answer false in silence -- the verdict side had exactly that hole.
  it "refuses a verdict outside the closed set" do
    expect { described_class::Unsettled.new(intent: promote, verdict: "banana") }
      .to raise_error(ArgumentError, /verdict/)
    expect(described_class::VERDICTS).to eq(%w[completed_externally needs_retry])
  end

  it "answers a report that is a deeply frozen, shareable value" do
    intent = promote

    expect(reconcile([intent, settled_by(intent), pr_create]).report).to be_deeply_frozen
  end
end
