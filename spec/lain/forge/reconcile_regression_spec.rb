# frozen_string_literal: true

# Regression coverage for Reconcile, grown from adversarial review probes.
#
# The nine probes that found defects (P9, P14, P15, P16, P21, P22, P23, P24,
# P27) are annotated FIXED and now assert the corrected behaviour -- each has a
# named counterpart in reconcile_spec.rb, which is where the obligation lives.
# The evidence is what the probe ORIGINALLY showed; the assertion has to track
# the code or this file stops being runnable evidence at all.
module ForgeProbeSupport
  REF = "refs/heads/epic/demo/a1"

  # A world that COUNTS what it is asked, so "does Reconcile ask twice" is
  # measurable rather than argued.
  class Counting
    attr_reader :calls

    def initialize(refs: {}, states: {}, heads: {})
      @refs = refs
      @states = states
      @heads = heads
      @calls = []
    end

    def ref_exists?(ref)
      @calls << [:ref_exists?, ref]
      @refs.key?(ref)
    end

    def sha_of(ref)
      @calls << [:sha_of, ref]
      @refs[ref]
    end

    def pr_state(number)
      @calls << [:pr_state, number]
      @states[number]
    end

    def pr_for(head:)
      @calls << [:pr_for, head]
      @heads[head]
    end
  end

  # A plausible real `gh`: the answer changes between calls (someone pushed).
  class Drifting
    def initialize(answers) = (@answers = answers)

    def ref_exists?(_ref) = @answers.shift
    def sha_of(_ref) = "cafe"
    def pr_state(_number) = "OPEN"
    # The keyword is named because the duck names it; this world simply has no
    # pull requests.
    # rubocop:disable Lint/UnusedMethodArgument
    def pr_for(head:) = nil
    # rubocop:enable Lint/UnusedMethodArgument
  end
end

RSpec.describe "T7 probes" do
  def promote(sha: "cafe", slug: "demo", issue: "a1", ref: ForgeProbeSupport::REF)
    Lain::Forge::Intent.new(action: "promote", epic_slug: slug, issue_id: issue,
                            params: { "ref" => ref, "sha" => sha })
  end

  def pr_merge(number: 12)
    Lain::Forge::Intent.new(action: "pr_merge", epic_slug: "demo", issue_id: "a1",
                            params: { "number" => number })
  end

  def ack(intent, **over) = Lain::Forge::Outcome.new(intent_id: intent.intent_id, ok: true, **over)

  def fold(records, world:)
    Lain::Forge::Reconcile.new(entries: records.map(&:to_journal), world:)
  end

  let(:empty) { ForgeProbeSupport::Counting.new }

  # ---------- the pairing law ----------

  it "P1: three identical intents and two outcomes settles the first two, leaves one" do
    a = promote
    b = promote
    c = promote
    report = fold([a, b, c, ack(a), ack(b)], world: empty)

    expect(report.settled.size).to eq(2)
    expect(report.unsettled.size).to eq(1)
    expect(report.orphans).to be_empty
  end

  it "P2: an outcome arriving BEFORE its intent orphans, and the intent stays unsettled" do
    a = promote
    report = fold([ack(a), a], world: empty)

    # Both halves of a settled pair are present in the file, yet nothing pairs.
    expect(report.orphans.size).to eq(1)
    expect(report.unsettled.size).to eq(1)
    expect(report.unsettled.first).to be_needs_retry
    expect(report.orphans.first.intent_id).to eq(report.unsettled.first.intent.intent_id)
    # FIXED: still single-pass, per the card -- but the state is now FLAGGED
    # rather than presented as two unrelated facts.
    expect(report.misordered).to eq([a.intent_id])
  end

  it "P3: the same outcome recorded twice settles once and orphans once" do
    a = promote
    report = fold([a, ack(a), ack(a)], world: empty)

    expect(report.settled.size).to eq(1)
    expect(report.orphans.size).to eq(1)
  end

  it "P4: different actions sharing params do NOT collide -- action is in the address" do
    ref_only = { "ref" => ForgeProbeSupport::REF }
    p1 = Lain::Forge::Intent.new(action: "promote", epic_slug: "d", issue_id: "a", params: ref_only)
    p2 = Lain::Forge::Intent.new(action: "pr_create", epic_slug: "d", issue_id: "a", params: ref_only)

    expect(p1.intent_id).not_to eq(p2.intent_id)
  end

  it "P5: an orphan sitting BETWEEN valid pairs is named and neither pair is disturbed" do
    a = promote
    b = pr_merge
    stray = Lain::Forge::Outcome.new(intent_id: "blake3:nobody", ok: false)
    world = ForgeProbeSupport::Counting.new(states: { 12 => "MERGED" })
    report = fold([a, ack(a), stray, b, ack(b)], world:)

    expect(report.settled.size).to eq(2)
    expect(report.orphans).to eq([stray])
    expect(report.unsettled).to be_empty
  end

  it "P6: a journal of pure outcomes is all orphans, nothing dropped" do
    report = fold([ack(promote), ack(pr_merge)], world: empty)

    expect(report.orphans.size).to eq(2)
    expect(report.settled).to be_empty
    expect(report.unsettled).to be_empty
  end

  # ---------- the address ----------

  it "P7: two DIFFERENT epics performing the same action with identical params collide" do
    x = promote(slug: "alpha", issue: "one", ref: "refs/heads/release")
    y = promote(slug: "beta", issue: "two", ref: "refs/heads/release")

    expect(x.intent_id).to eq(y.intent_id)

    # ...and beta's outcome settles alpha's intent.
    report = fold([x, y, ack(y)], world: empty)
    expect(report.settled.first.intent.epic_slug).to eq("alpha")
    expect(report.unsettled.first.intent.epic_slug).to eq("beta")
  end

  it "P8: an orphan outcome carries no epic or issue -- only a digest" do
    stray = Lain::Forge::Outcome.new(intent_id: "blake3:nobody", ok: false)

    expect(fold([stray], world: empty).orphans.first.to_h.keys)
      .to eq(%i[intent_id ok observed detail])
  end

  # ---------- idempotence ----------

  # FIXED: memoized on intent_id, which is by construction the same question.
  it "P9: the world is asked once per intent_id -- repeats ARE deduped" do
    a = promote
    world = ForgeProbeSupport::Counting.new
    fold([a, promote, promote], world:)

    expect(world.calls).to eq([[:ref_exists?, ForgeProbeSupport::REF]])
  end

  it "P10: a promote costs TWO non-atomic round trips when the ref exists" do
    world = ForgeProbeSupport::Counting.new(refs: { ForgeProbeSupport::REF => "cafe" })
    fold([promote], world:)

    expect(world.calls).to eq([[:ref_exists?, ForgeProbeSupport::REF],
                               [:sha_of, ForgeProbeSupport::REF]])
  end

  it "P11: a world that answers differently on the second run yields a DIFFERENT report, silently" do
    world = ForgeProbeSupport::Drifting.new([false, true])
    records = [promote].map(&:to_journal)

    first = Lain::Forge::Reconcile.new(entries: records, world:).report
    second = Lain::Forge::Reconcile.new(entries: records, world:).report

    expect(first).not_to eq(second)
  end

  it "P12: the report's arrays are frozen and its members deeply frozen" do
    a = promote
    report = fold([a, ack(a), pr_merge], world: empty).report

    expect(report.settled).to be_frozen
    expect(report.unsettled).to be_frozen
    expect(report.orphans).to be_frozen
    expect(Ractor.shareable?(report)).to be(true)
  end

  it "P13: entries given as a one-shot lazy enumerator reconcile empty the second time" do
    a = promote
    entries = [a.to_journal, ack(a).to_journal].lazy.map { |record| record }

    first = Lain::Forge::Reconcile.new(entries:, world: empty).report
    second = Lain::Forge::Reconcile.new(entries:, world: empty).report

    expect(first).to eq(second) # documents whether re-enumeration holds
  end

  # ---------- unobservable ----------

  # FIXED: named in Report#unaddressable rather than raised out of the fold.
  it "P14: a missing param key names the key AND the action" do
    blind = Lain::Forge::Intent.new(action: "pr_merge", epic_slug: "d", issue_id: "a", params: {})

    expect(fold([blind], world: empty).unaddressable.first.reason).to match(/pr_merge.*"number"/m)
  end

  # FIXED: both addresses are bound before the world is consulted.
  it "P15: a promote missing only sha is judged BEFORE the world is asked" do
    world = ForgeProbeSupport::Counting.new(refs: { ForgeProbeSupport::REF => "cafe" })
    blind = Lain::Forge::Intent.new(action: "promote", epic_slug: "d", issue_id: "a",
                                    params: { "ref" => ForgeProbeSupport::REF })

    expect(fold([blind], world:).unaddressable.first.reason).to include("sha")
    expect(world.calls).to be_empty
  end

  # FIXED: the observation phase names its casualties instead of taking the
  # report with it -- a resume with one malformed line still says what landed.
  it "P16: one unaddressable intent costs the report nothing else" do
    a = promote
    blind = Lain::Forge::Intent.new(action: "pr_merge", epic_slug: "d", issue_id: "a", params: {})
    report = fold([a, ack(a), blind], world: empty)

    expect(report.settled.size).to eq(1)
    expect(report.unaddressable.size).to eq(1)
  end

  # ---------- journal_type override ----------

  it "P17: the overridden type round-trips through Journal.records(type:)" do
    a = promote
    entries = [a.to_journal, ack(a).to_journal]

    expect(Lain::Journal.records(entries, type: "forge_intent").to_a.size).to eq(1)
    expect(Lain::Journal.records(entries, type: "forge_outcome").to_a.size).to eq(1)
    expect(Lain::Journal.records(entries, type: "intent").to_a).to be_empty
  end

  it "P18: the derived name and the overridden name differ -- nothing pins them equal" do
    derived = Lain::Forge::Intent.instance_method(:journal_type)
    expect(derived.owner).to eq(Lain::Forge::Intent)
    expect(Lain::Telemetry::Journalable.instance_method(:journal_type)
             .bind_call(promote)).to eq("intent")
  end

  # ---------- params shape ----------

  it "P19: a Symbol-keyed param addresses identically but a string/int key does not" do
    by_string = Lain::Forge::Intent.new(action: "pr_merge", epic_slug: "d", issue_id: "a",
                                        params: { "number" => 12 })
    by_symbol = Lain::Forge::Intent.new(action: "pr_merge", epic_slug: "d", issue_id: "a",
                                        params: { number: 12 })
    by_text = Lain::Forge::Intent.new(action: "pr_merge", epic_slug: "d", issue_id: "a",
                                      params: { "number" => "12" })

    expect(by_symbol.intent_id).to eq(by_string.intent_id)
    expect(by_text.intent_id).not_to eq(by_string.intent_id)
  end

  it "P20: a pr_merge whose number was journaled as JSON reads back as an Integer key lookup" do
    intent = pr_merge(number: 12)
    line = Lain::Journal.new(io: StringIO.new).then { intent.to_journal }
    world = ForgeProbeSupport::Counting.new(states: { 12 => "MERGED" })

    expect(Lain::Forge::Reconcile.new(entries: [JSON.parse(JSON.generate(line))], world:)
             .unsettled.first).to be_completed_externally
  end
end

RSpec.describe "T7 probes, second pass" do
  let(:ref) { ForgeProbeSupport::REF }

  def blind_promote
    Lain::Forge::Intent.new(action: "promote", epic_slug: "d", issue_id: "a",
                            params: { "ref" => ForgeProbeSupport::REF })
  end

  def fold(records, world:)
    Lain::Forge::Reconcile.new(entries: records.map(&:to_journal), world:)
  end

  # FIXED: unreadable is unreadable regardless of what the remote holds.
  it "P21: a promote missing `sha` is unaddressable when the ref is absent" do
    world = ForgeProbeSupport::Counting.new # no refs at all

    expect(fold([blind_promote], world:).unaddressable.size).to eq(1)
    expect(fold([blind_promote], world:).unsettled).to be_empty
  end

  it "P22: the same intent reads the same way when the ref DOES exist" do
    world = ForgeProbeSupport::Counting.new(refs: { ForgeProbeSupport::REF => "cafe" })

    expect(fold([blind_promote], world:).unaddressable.first.reason).to include("sha")
  end

  # FIXED: the verdict set is closed by a guard, so a typo cannot answer false
  # to both predicates in silence.
  it "P23: Unsettled refuses a verdict that is neither constant" do
    expect { Lain::Forge::Reconcile::Unsettled.new(intent: blind_promote, verdict: "banana") }
      .to raise_error(ArgumentError, /verdict/)
  end

  # FIXED: two absences of knowledge are not a confirmation. A blank address is
  # refused as hard as a missing one.
  it "P24: a promote whose sha param is nil is unaddressable, not confirmed" do
    world = ForgeProbeSupport::Counting.new(refs: { ForgeProbeSupport::REF => nil })
    nilled = Lain::Forge::Intent.new(action: "promote", epic_slug: "d", issue_id: "a",
                                     params: { "ref" => ForgeProbeSupport::REF, "sha" => nil })

    expect(fold([nilled], world:).unaddressable.size).to eq(1)
    expect(fold([nilled], world:).unsettled).to be_empty
  end

  it "P25: an outcome whose ok is false still SETTLES the intent -- failure is settledness" do
    intent = blind_promote
    failed = Lain::Forge::Outcome.new(intent_id: intent.intent_id, ok: false,
                                      detail: { "error" => "diverged" })

    report = fold([intent, failed], world: ForgeProbeSupport::Counting.new)

    expect(report.settled.size).to eq(1)
    expect(report.unsettled).to be_empty
  end

  it "P26: params are deeply frozen and nested values too" do
    nested = Lain::Forge::Intent.new(action: "pr_create", epic_slug: "d", issue_id: "a",
                                     params: { "head" => "h", "labels" => %w[a b] })

    expect(nested.params).to be_frozen
    expect(nested.params["labels"]).to be_frozen
    expect(nested.params["labels"].first).to be_frozen
  end

  # FIXED: an unaddressable intent no longer aborts, so the equality this probe
  # was named for is finally observable.
  it "P27: two runs over one journal and one world yield equal reports" do
    intent = blind_promote
    world = ForgeProbeSupport::Counting.new(refs: { ForgeProbeSupport::REF => "cafe" })

    expect(fold([intent], world:).report).to eq(fold([intent], world:).report)
  end
end
