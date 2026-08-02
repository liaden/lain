# frozen_string_literal: true

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module ForgeLandingSpecSupport
  # The pull request's head ref, and the promotion's full ref for the same
  # branch. Both spellings appear because they address DIFFERENT things: a
  # promote intent carries `refs/heads/...` and a pr_create intent carries the
  # short head, and a landing that mixed them would look up the wrong one.
  HEAD = "epic/demo/a1"
  REF = "refs/heads/epic/demo/a1"
  # A full object name, because {Lain::Forge::Promotion::Remote#anchored!}
  # refuses anything else and a fixture must not be the reason a spec passes.
  SHA = "a" * 40
  APPROVED = "blake3:approved"
end

# One issue's serial landing: gate, promote, open, merge, move to done -- every
# step journaled as an intent before it is attempted, and resumable from
# whatever the journal and the world can be made to agree on.
#
# What is pinned here is that ONE sequence runs both ways. `#call` folds the
# plan against no evidence and `.resume` folds the same plan against a
# {Lain::Forge::Reconcile} report; a fact asserted about one is a fact about the
# other, which is the whole reason there is no second copy of the sequence.
RSpec.describe Lain::Forge::Landing do
  let(:journal) { [] }
  let(:artifact) { instance_double(Lain::Epic::Submission, digest: ForgeLandingSpecSupport::APPROVED) }
  let(:gate) { instance_double(Lain::Approval::Gate, ensure_approved!: ForgeLandingSpecSupport::APPROVED) }
  let(:scribe) { instance_double(Lain::Epic::Scribe, issue_moved: nil) }
  let(:promotion) { instance_double(Lain::Forge::Promotion) }
  let(:promotion_answer) { Lain::Forge::Gh::Answer.new(ok: true, detail: { "reason" => "promoted" }) }

  let(:executor) do
    instance_double(Lain::Forge::Gh, pr_create: answer(value: 7), pr_merge: answer(value: 7),
                                     merge_state: answer(value: "CLEAN"))
  end

  let(:journaled) { Lain::Forge::Journaled.new(executor, journal:, epic_slug: "demo", issue_id: "a1") }
  let(:landing) { described_class.new(**wiring) }

  # A Promotion is not a gh verb, so it owes its own intent/outcome pair through
  # {Lain::Forge::Journaled#attempt} -- which is exactly how the real one does
  # it. Stubbing it as a bare answer would leave the promote step's record out
  # of the journal, and the first scenario is about that record existing.
  before do
    allow(promotion).to receive(:call) do |sha:|
      journaled.attempt(action: Lain::Forge::PROMOTE,
                        params: { "ref" => ForgeLandingSpecSupport::REF, "sha" => sha }) do
        promotion_answer
      end
    end
  end

  def wiring
    { epic_slug: "demo", issue_id: "a1", artifact:, sha: ForgeLandingSpecSupport::SHA, gate:, promotion:, journaled:,
      scribe: }
  end

  def answer(value:) = Lain::Forge::Gh::Answer.new(ok: true, detail: { "value" => value })

  def refused(reason:) = Lain::Forge::Gh::Answer.new(ok: false, detail: { "reason" => reason })

  # The `world` duck {Lain::Forge::Reconcile} and {Lain::Forge::Landing} both
  # observe through, as a verifying double against the real class so a renamed
  # method breaks here rather than in production.
  #
  # Fixed tables rather than a script, for {Lain::Forge::Reconcile}'s own
  # reason: the fixpoint claim is "same entries, same world, same answer", and a
  # world that replied differently on the second ask would make the second run
  # mean something else.
  def world(refs: {}, states: {}, heads: {})
    answers = { ref_exists?: ->(ref) { refs.key?(ref) }, sha_of: ->(ref) { refs[ref] },
                pr_state: ->(number) { states[number] }, pr_for: ->(head:) { heads[head] } }
    instance_double(Lain::Forge::Reconcile::World).tap do |double|
      answers.each { |message, reply| allow(double).to receive(message, &reply) }
    end
  end

  def pushed = { ForgeLandingSpecSupport::REF => ForgeLandingSpecSupport::SHA }

  # --- journal fixtures, built through the real producers -------------------

  def promote_intent(sha: ForgeLandingSpecSupport::SHA)
    Lain::Forge::Intent.new(action: Lain::Forge::PROMOTE, epic_slug: "demo", issue_id: "a1",
                            params: { "ref" => ForgeLandingSpecSupport::REF, "sha" => sha })
  end

  # The SAME params {Lain::Forge::Journaled#pr_create} stamps, so the fixture
  # shares its intent_id with what a live run would write.
  def create_intent
    Lain::Forge::Intent.new(action: Lain::Forge::PR_CREATE, epic_slug: "demo", issue_id: "a1",
                            params: { "head" => ForgeLandingSpecSupport::HEAD, "base" => "main" })
  end

  def merge_intent(number: 7)
    Lain::Forge::Intent.new(action: Lain::Forge::PR_MERGE, epic_slug: "demo", issue_id: "a1",
                            params: { "number" => number })
  end

  def outcome(intent, **fields) = Lain::Forge::Outcome.new(intent_id: intent.intent_id, observed: false, **fields)

  def settled(intent, **detail) = outcome(intent, ok: true, detail:)

  def settled_by_refusal(intent, **detail) = outcome(intent, ok: false, detail:)

  def entries(*records) = records.map(&:to_journal)

  # A journal that already carries the whole protocol, settled.
  def whole_landing
    promote = promote_intent
    create = create_intent
    merge = merge_intent
    entries(promote, settled(promote), create, settled(create, "value" => 7), merge, settled(merge, "value" => 7))
  end

  # --- reading back what the run wrote --------------------------------------

  def intents = journal.grep(Lain::Forge::Intent)

  def actions = intents.map(&:action)

  # What the run journaled, folded by the very object a resume folds it with:
  # "a chain of settled intents" is a claim about {Lain::Forge::Reconcile}'s
  # report, so it is asserted as one rather than as a hand-walked array.
  def chain = Lain::Forge::Reconcile.new(entries: journal.map(&:to_journal), world:)

  # =========================================================================
  # Scenario: a landing is a chain of settled intents
  # =========================================================================

  it "journals an intent/outcome pair for promote, pr_create and pr_merge, then moves the issue to done" do
    result = landing.call

    expect(result).to be_ok
    expect(chain.settled.map { |item| item.intent.action }).to eq(%w[promote pr_create pr_merge])
    expect(chain.outstanding).to be_empty
    expect(chain.orphans).to be_empty
    expect(scribe).to have_received(:issue_moved).with("a1", from: "in_flight", to: Lain::Epic::DONE)
  end

  it "answers the pull request number the merge named" do
    expect(landing.call.value).to eq(7)
  end

  # S3: `observed` is the tier's honesty flag -- true means the effect was found
  # already in place rather than performed.
  it "does not claim to have observed effects it performed" do
    expect(landing.call).not_to be_observed
  end

  # =========================================================================
  # Scenario: no approval, no intent
  # =========================================================================

  it "raises NotApproved and journals no forge_intent when the gate never approved the digest" do
    allow(gate).to receive(:ensure_approved!).and_raise(Lain::Approval::Gate::NotApproved)

    expect { landing.call }.to raise_error(Lain::Approval::Gate::NotApproved)
    expect(journal).to be_empty
    expect(promotion).not_to have_received(:call)
  end

  it "checks the gate before the first intent on the resume path too" do
    allow(gate).to receive(:ensure_approved!).and_raise(Lain::Approval::Gate::NotApproved)

    expect { described_class.resume(entries: [], world:, **wiring) }
      .to raise_error(Lain::Approval::Gate::NotApproved)
    expect(journal).to be_empty
  end

  # =========================================================================
  # Scenario: resume continues instead of repeating
  # =========================================================================

  it "resumes at pr_create when the journal settled the promote and the branch stands at the sha" do
    promote = promote_intent

    result = described_class.resume(entries: entries(promote, settled(promote)), world: world(refs: pushed), **wiring)

    expect(result).to be_ok
    expect(actions).to eq(%w[pr_create pr_merge])
    expect(promotion).not_to have_received(:call)
  end

  # =========================================================================
  # Scenario: resume after a crashed pr_create finds its PR by head ref
  # =========================================================================

  it "adopts the pull request the world reports for the head ref rather than opening a second one" do
    promote = promote_intent
    open_pr = { ForgeLandingSpecSupport::HEAD => { "number" => 7 } }

    result = described_class.resume(entries: entries(promote, settled(promote), create_intent),
                                    world: world(refs: pushed, heads: open_pr), **wiring)

    expect(result).to be_ok
    expect(executor).not_to have_received(:pr_create)
    expect(actions).to eq(%w[pr_merge])
    expect(executor).to have_received(:pr_merge).with(number: 7, auto: false)
  end

  # =========================================================================
  # Scenario: resume is a fixpoint against an unchanged world
  # =========================================================================

  it "emits no new intents and no second transition when a resume is repeated against an unchanged world" do
    fixture = entries(promote_intent, settled(promote_intent))
    unchanging = world(refs: pushed)

    described_class.resume(entries: fixture, world: unchanging, **wiring)
    first_run = journal.dup
    described_class.resume(entries: fixture + entries(*first_run), world: unchanging, **wiring)

    expect(journal.drop(first_run.size)).to be_empty
    expect(scribe).to have_received(:issue_moved).once
  end

  it "answers observed, carrying the recorded number, when a resume finds every effect already in place" do
    result = described_class.resume(entries: whole_landing, world: world(refs: pushed), **wiring)

    expect(result).to be_ok
    expect(result).to be_observed
    expect(result.value).to eq(7)
    expect(journal).to be_empty
    expect(scribe).not_to have_received(:issue_moved)
  end

  # B4's second half: a MERGED pull request's mergeStateStatus is not CLEAN, so
  # a completed landing that re-asked would report itself conflicted forever.
  # The merge step does not ask, because it does not run.
  it "asks for no merge state on a resume whose merge the journal already settled" do
    described_class.resume(entries: whole_landing, world: world(refs: pushed), **wiring)

    expect(executor).not_to have_received(:merge_state)
  end

  # =========================================================================
  # Scenario: a dirty merge state stops the run
  # =========================================================================

  it "stops with a conflicted outcome and journals no pr_merge intent when merge_state answers DIRTY" do
    allow(executor).to receive(:merge_state).and_return(answer(value: "DIRTY"))

    result = landing.call

    expect(result).not_to be_ok
    expect(result.detail).to include("reason" => "conflicted", "state" => "DIRTY")
    expect(actions).to eq(%w[promote pr_create])
    expect(executor).not_to have_received(:pr_merge)
    expect(scribe).not_to have_received(:issue_moved)
  end

  # S5: {Lain::Forge::Gh::Poll} answers UNKNOWN when its own bound runs out --
  # "GitHub has not finished computing mergeability", usually CI still running.
  # Calling that a merge conflict sends a human to resolve nothing.
  it "does not call an UNKNOWN merge state a conflict" do
    allow(executor).to receive(:merge_state).and_return(answer(value: "UNKNOWN"))

    result = landing.call

    expect(result).not_to be_ok
    expect(result.detail).to include("state" => "UNKNOWN")
    expect(result.detail["reason"]).not_to eq("conflicted")
    expect(executor).not_to have_received(:pr_merge)
  end

  it "stops on a merge_state the executor could not read at all" do
    allow(executor).to receive(:merge_state)
      .and_return(refused(reason: "missing_field"))

    expect(landing.call).not_to be_ok
    expect(executor).not_to have_received(:pr_merge)
  end

  # =========================================================================
  # B1: every step's verdict is READ, and any of them can stop the run
  # =========================================================================

  it "stops on a promotion that refused, without opening a pull request" do
    refusal = Lain::Forge::Gh::Answer.new(ok: false, detail: { "reason" => "diverged", "message" => "stands at cafe" })
    allow(promotion).to receive(:call).and_return(refusal)

    result = landing.call

    expect(result).not_to be_ok
    expect(result.detail).to include("reason" => "diverged")
    expect(executor).not_to have_received(:pr_create)
    expect(scribe).not_to have_received(:issue_moved)
  end

  it "stops on a promotion that refused while resuming, without opening a pull request" do
    refusal = refused(reason: "namespace_conflict")
    allow(promotion).to receive(:call).and_return(refusal)

    result = described_class.resume(entries: [], world:, **wiring)

    expect(result).not_to be_ok
    expect(result.detail).to include("reason" => "namespace_conflict")
    expect(executor).not_to have_received(:pr_create)
  end

  it "stops on a pr_create that refused, without merging anything" do
    allow(executor).to receive(:pr_create)
      .and_return(refused(reason: "refused"))

    expect(landing.call).not_to be_ok
    expect(executor).not_to have_received(:pr_merge)
    expect(scribe).not_to have_received(:issue_moved)
  end

  it "stops on a pr_merge that refused, without moving the issue" do
    allow(executor).to receive(:pr_merge)
      .and_return(refused(reason: "refused"))

    expect(landing.call).not_to be_ok
    expect(scribe).not_to have_received(:issue_moved)
  end

  # =========================================================================
  # B1b: settled-ness folds on `ok`
  # =========================================================================

  it "re-promotes when the journal settled the promote with a NOT-ok outcome" do
    promote = promote_intent
    history = entries(promote, settled_by_refusal(promote, "reason" => "diverged"))

    result = described_class.resume(entries: history, world:, **wiring)

    expect(result).to be_ok
    expect(promotion).to have_received(:call).with(sha: ForgeLandingSpecSupport::SHA)
    expect(actions).to eq(%w[promote pr_create pr_merge])
  end

  # The failed outcome carries a `value` on purpose: a refusal whose detail
  # still holds a stale number is exactly the record that must not be read as
  # "the pull request is number 99, go merge it".
  it "re-opens the pull request when the journal settled the pr_create with a NOT-ok outcome" do
    promote = promote_intent
    create = create_intent
    history = entries(promote, settled(promote), create,
                      settled_by_refusal(create, "reason" => "refused", "value" => 99))

    described_class.resume(entries: history, world: world(refs: pushed), **wiring)

    expect(executor).to have_received(:pr_create)
    expect(executor).to have_received(:pr_merge).with(number: 7, auto: false)
    expect(actions).to eq(%w[pr_create pr_merge])
  end

  # =========================================================================
  # S4/S5a: a stop is a structured outcome, never a raise and never a Report
  # =========================================================================

  it "answers a not-ok Answer, not a Report, when an outcome answers no intent the journal holds" do
    orphan = Lain::Forge::Outcome.new(intent_id: "blake3:nobody", ok: true, observed: false, detail: {})

    result = described_class.resume(entries: entries(orphan), world:, **wiring)

    expect(result).to respond_to(:ok?)
    expect(result).not_to be_ok
    expect(result.detail["message"]).to include("blake3:nobody")
    expect(journal).to be_empty
  end

  it "escalates an intent whose params cannot address the world, rather than folding it to not-done" do
    blind = Lain::Forge::Intent.new(action: Lain::Forge::PR_MERGE, epic_slug: "demo", issue_id: "a1",
                                    params: { "number" => "  " })

    result = described_class.resume(entries: entries(blind), world:, **wiring)

    expect(result).not_to be_ok
    expect(result.detail["message"]).to include("pr_merge")
    expect(journal).to be_empty
  end

  # B5a: {Lain::Forge::Reconcile} catches Unobservable only inside the questions
  # IT asks. The head-ref lookup is asked outside that fold, and the first
  # version of this class let the exception escape `resume`.
  it "escalates instead of raising when the world cannot say which pull request the head ref carries" do
    unreadable = world(refs: pushed)
    allow(unreadable).to receive(:pr_for).and_raise(Lain::Forge::Unobservable, "GitHub returned 2 matches")

    result = described_class.resume(entries: entries(promote_intent), world: unreadable, **wiring)

    expect(result).not_to be_ok
    expect(result.detail["message"]).to include("2 matches")
    expect(journal).to be_empty
  end

  # S2: three speculative arms and a fallback put a raw Hash into `gh pr merge`'s
  # argv. A record with no number is named and refused.
  it "refuses a pull request record carrying no number rather than passing it along" do
    numberless = { ForgeLandingSpecSupport::HEAD => { "url" => "https://example.invalid/pull/7" } }

    result = described_class.resume(entries: entries(promote_intent), world: world(refs: pushed, heads: numberless),
                                    **wiring)

    expect(result).not_to be_ok
    expect(result.detail["message"]).to include("example.invalid")
    expect(executor).not_to have_received(:pr_merge)
  end

  # =========================================================================
  # S6: one executor collaborator, not two
  # =========================================================================

  it "takes no separate gh executor -- observations ride the journaled bracket" do
    expect { described_class.new(**wiring, gh: executor) }.to raise_error(ArgumentError, /gh/)
  end
end
