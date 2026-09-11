# frozen_string_literal: true

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module ForgeLandingSpecSupport
  # The pull request's head, and the promotion's full ref for the same branch:
  # a promote intent carries `refs/heads/...` and a pr_create intent the short
  # head, and a landing that mixed them would look up the wrong one.
  HEAD = "epic/demo"
  REF = "refs/heads/epic/demo"
  # A full object name, because {Lain::Forge::Promotion::Remote#anchored!}
  # refuses anything else and a fixture must not be the reason a spec passes.
  SHA = "a" * 40
end

# An epic's one pull request: promote `epic/<slug>`, open a pull request
# against main, merge it, delete the remote branch -- every step journaled as an
# intent before it is attempted, and resumable from whatever the journal and the
# world can be made to agree on. One sequence runs both ways: `#call` folds the
# plan against no evidence and `.resume` against a {Lain::Forge::Reconcile}
# report.
RSpec.describe Lain::Forge::Landing do
  let(:journal) { [] }
  let(:promotion) { instance_double(Lain::Forge::Promotion) }
  let(:promotion_answer) { Lain::Forge::Gh::Answer.new(ok: true, detail: { "reason" => "promoted" }) }
  let(:deletion_answer) { Lain::Forge::Gh::Answer.new(ok: true, detail: { "reason" => "deleted" }) }

  let(:executor) do
    instance_double(Lain::Forge::Gh, pr_create: answer(value: 7), pr_merge: answer(value: 7),
                                     merge_state: answer(value: "CLEAN"), pr_view: answer(value: { "state" => "OPEN" }))
  end

  let(:journaled) do
    Lain::Forge::Journaled.new(executor, journal:, epic_slug: "demo", issue_id: described_class::WHOLE_EPIC)
  end
  let(:landing) { described_class.new(**wiring) }

  # A Promotion is not a gh verb, so it owes its own intent/outcome pairs
  # through {Lain::Forge::Journaled#attempt}, exactly as the real one does.
  before do
    allow(promotion).to receive(:call) do |sha:|
      journaled.attempt(action: Lain::Forge::PROMOTE,
                        params: { "ref" => ForgeLandingSpecSupport::REF, "sha" => sha }) do
        promotion_answer
      end
    end
    allow(promotion).to receive(:delete) do |sha:|
      journaled.attempt(action: Lain::Forge::BRANCH_DELETE,
                        params: { "ref" => ForgeLandingSpecSupport::REF, "sha" => sha }) { deletion_answer }
    end
  end

  def wiring = { epic_slug: "demo", sha: ForgeLandingSpecSupport::SHA, promotion:, journaled: }

  def answer(value:) = Lain::Forge::Gh::Answer.new(ok: true, detail: { "value" => value })

  def refused(reason:) = Lain::Forge::Gh::Answer.new(ok: false, detail: { "reason" => reason })

  # The `world` duck, as a verifying double against the real class. Fixed
  # tables rather than a script: the fixpoint claim is "same entries, same
  # world, same answer".
  def world(refs: {}, states: {}, heads: {})
    answers = { ref_exists?: ->(ref) { refs.key?(ref) }, sha_of: ->(ref) { refs[ref] },
                pr_state: ->(number) { states[number] }, pr_for: ->(head:) { heads[head] } }
    instance_double(Lain::Forge::Reconcile::World).tap do |double|
      answers.each { |message, reply| allow(double).to receive(message, &reply) }
    end
  end

  def pushed = { ForgeLandingSpecSupport::REF => ForgeLandingSpecSupport::SHA }

  # --- journal fixtures, built through the real producers -------------------

  def intent(action, params)
    Lain::Forge::Intent.new(action:, epic_slug: "demo", issue_id: described_class::WHOLE_EPIC, params:)
  end

  def promote_intent
    intent(Lain::Forge::PROMOTE, "ref" => ForgeLandingSpecSupport::REF,
                                 "sha" => ForgeLandingSpecSupport::SHA)
  end

  def create_intent = intent(Lain::Forge::PR_CREATE, "head" => ForgeLandingSpecSupport::HEAD, "base" => "main")

  def merge_intent = intent(Lain::Forge::PR_MERGE, "number" => 7)

  def outcome(intent, **fields) = Lain::Forge::Outcome.new(intent_id: intent.intent_id, observed: false, **fields)

  def settled(intent, **detail) = outcome(intent, ok: true, detail:)

  def settled_by_refusal(intent, **detail) = outcome(intent, ok: false, detail:)

  def entries(*records) = records.map(&:to_journal)

  def merged_landing
    entries(promote_intent, settled(promote_intent), create_intent, settled(create_intent, "value" => 7),
            merge_intent, settled(merge_intent, "value" => 7))
  end

  def intents = journal.grep(Lain::Forge::Intent)

  def actions = intents.map(&:action)

  def chain = Lain::Forge::Reconcile.new(entries: journal.map(&:to_journal), world:)

  describe "an epic's landing is a chain of settled intents" do
    it "journals promote, pr_create, pr_merge and branch_delete, settled, in that order" do
      result = landing.call

      expect(result).to be_ok
      expect(chain.settled.map { |item| item.intent.action }).to eq(%w[promote pr_create pr_merge branch_delete])
      expect(chain.outstanding).to be_empty
    end

    it "opens its one pull request from the epic branch against main" do
      landing.call

      expect(executor).to have_received(:pr_create)
        .once.with(hash_including(base: "main", head: ForgeLandingSpecSupport::HEAD))
    end

    it "attributes every intent to the whole epic, since no single issue owns the pull request" do
      landing.call

      expect(intents.map(&:issue_id).uniq).to eq([described_class::WHOLE_EPIC])
    end

    it "answers the pull request number, and does not claim to have observed what it performed" do
      result = landing.call

      expect(result.value).to eq(7)
      expect(result).not_to be_observed
    end

    it "deletes the remote branch at the sha it promoted" do
      landing.call

      expect(promotion).to have_received(:delete).with(sha: ForgeLandingSpecSupport::SHA)
    end
  end

  describe "resume continues instead of repeating" do
    it "resumes at pr_create when the journal settled the promote and the branch stands at the sha" do
      result = described_class.resume(entries: entries(promote_intent, settled(promote_intent)),
                                      world: world(refs: pushed), **wiring)

      expect(result).to be_ok
      expect(actions).to eq(%w[pr_create pr_merge branch_delete])
      expect(promotion).not_to have_received(:call)
    end

    it "adopts the pull request the world reports for the head rather than opening a second one" do
      open_pr = { ForgeLandingSpecSupport::HEAD => { "number" => 7 } }

      described_class.resume(entries: entries(promote_intent, settled(promote_intent), create_intent),
                             world: world(refs: pushed, heads: open_pr), **wiring)

      expect(executor).not_to have_received(:pr_create)
      expect(executor).to have_received(:pr_merge).with(number: 7, auto: false)
    end

    it "deletes, and only deletes, when the merge settled and the delete never ran" do
      described_class.resume(entries: merged_landing, world: world(refs: pushed), **wiring)

      expect(actions).to eq(%w[branch_delete])
      expect(executor).not_to have_received(:merge_state)
    end

    # An epic that gained an issue after it finished has new commits for
    # main: a landing is addressed by the sha it lands, so another sha's
    # settled steps belong to another landing.
    it "lands a moved tip as a new landing, whatever an earlier sha's landing settled" do
      earlier_promote = intent(Lain::Forge::PROMOTE, "ref" => ForgeLandingSpecSupport::REF, "sha" => "b" * 40)
      earlier_delete = intent(Lain::Forge::BRANCH_DELETE, "ref" => ForgeLandingSpecSupport::REF, "sha" => "b" * 40)
      earlier = entries(earlier_promote, settled(earlier_promote), create_intent, settled(create_intent, "value" => 7),
                        merge_intent, settled(merge_intent, "value" => 7), earlier_delete, settled(earlier_delete))

      result = described_class.resume(entries: earlier, world:, **wiring)

      expect(result).to be_ok
      expect(actions).to eq(%w[promote pr_create pr_merge branch_delete])
      expect(promotion).to have_received(:call).with(sha: ForgeLandingSpecSupport::SHA)
    end

    it "is a fixpoint: a repeated resume against an unchanged world journals nothing new" do
      fixture = entries(promote_intent, settled(promote_intent))
      unchanging = world(refs: pushed)

      described_class.resume(entries: fixture, world: unchanging, **wiring)
      first_run = journal.dup
      described_class.resume(entries: fixture + entries(*first_run), world: unchanging, **wiring)

      expect(journal.drop(first_run.size)).to be_empty
    end

    it "answers observed, carrying the number, when every effect is already in place" do
      delete = intent(Lain::Forge::BRANCH_DELETE, "ref" => ForgeLandingSpecSupport::REF,
                                                  "sha" => ForgeLandingSpecSupport::SHA)
      done = merged_landing + entries(delete, settled(delete))

      result = described_class.resume(entries: done, world:, **wiring)

      expect(result).to be_ok
      expect(result).to be_observed
      expect(result.value).to eq(7)
      expect(journal).to be_empty
    end
  end

  describe "any step can stop the run" do
    it "stops with a conflicted outcome and journals no pr_merge when the merge state is DIRTY" do
      allow(executor).to receive(:merge_state).and_return(answer(value: "DIRTY"))

      result = landing.call

      expect(result.detail).to include("reason" => "conflicted", "state" => "DIRTY")
      expect(actions).to eq(%w[promote pr_create])
      expect(promotion).not_to have_received(:delete)
    end

    # A merged pull request's merge state is never CLEAN, so a landing that
    # only asked for it would retry forever after somebody else merged.
    it "reads a pull request someone else merged as merged, and goes on to delete the branch" do
      allow(executor).to receive_messages(pr_view: answer(value: { "state" => "MERGED" }),
                                          merge_state: answer(value: "UNKNOWN"))

      result = landing.call

      expect(result).to be_ok
      expect(executor).not_to have_received(:pr_merge)
      expect(promotion).to have_received(:delete)
      expect(chain.settled.find { |item| item.intent.action == "pr_merge" }.outcome).to be_observed
    end

    it "does not call an UNKNOWN merge state a conflict" do
      allow(executor).to receive(:merge_state).and_return(answer(value: "UNKNOWN"))

      expect(landing.call.detail["reason"]).not_to eq("conflicted")
      expect(executor).not_to have_received(:pr_merge)
    end

    it "stops on a promotion that refused, without opening a pull request" do
      allow(promotion).to receive(:call).and_return(refused(reason: "namespace_conflict"))

      result = landing.call

      expect(result.detail).to include("reason" => "namespace_conflict")
      expect(executor).not_to have_received(:pr_create)
    end

    it "stops on a pr_merge that refused, and deletes no branch" do
      allow(executor).to receive(:pr_merge).and_return(refused(reason: "refused"))

      expect(landing.call).not_to be_ok
      expect(promotion).not_to have_received(:delete)
    end

    it "stops, not ok, on a delete the remote refused" do
      allow(promotion).to receive(:delete).and_return(refused(reason: "diverged"))

      result = landing.call

      expect(result).not_to be_ok
      expect(result.detail).to include("reason" => "diverged")
    end

    it "re-promotes when the journal settled the promote with a NOT-ok outcome" do
      history = entries(promote_intent, settled_by_refusal(promote_intent, "reason" => "diverged"))

      described_class.resume(entries: history, world:, **wiring)

      expect(promotion).to have_received(:call).with(sha: ForgeLandingSpecSupport::SHA)
    end
  end

  describe "a stop is a structured outcome, never a raise" do
    it "answers not ok when an outcome answers no intent the journal holds" do
      orphan = Lain::Forge::Outcome.new(intent_id: "blake3:nobody", ok: true, observed: false, detail: {})

      result = described_class.resume(entries: entries(orphan), world:, **wiring)

      expect(result).not_to be_ok
      expect(result.detail["message"]).to include("blake3:nobody")
      expect(journal).to be_empty
    end

    it "escalates instead of raising when the world cannot say which pull request the head carries" do
      unreadable = world(refs: pushed)
      allow(unreadable).to receive(:pr_for).and_raise(Lain::Forge::Unobservable, "GitHub returned 2 matches")

      result = described_class.resume(entries: entries(promote_intent), world: unreadable, **wiring)

      expect(result.detail["message"]).to include("2 matches")
      expect(journal).to be_empty
    end
  end

  it "takes no separate gh executor -- observations ride the journaled bracket" do
    expect { described_class.new(**wiring, gh: executor) }.to raise_error(ArgumentError, /gh/)
  end

  # The per-issue pull request is gone: a landing names an epic, never an issue.
  it "takes no issue, gate or scribe" do
    expect { described_class.new(**wiring, issue_id: "a1") }.to raise_error(ArgumentError, /issue_id/)
  end
end
