# frozen_string_literal: true

require "stringio"

# Approval::Gate::Policy is HOW a verdict is reached, wrapped around the one
# Gate that reaches it. Each policy answers #decide by handing Gate a surface and
# a label, so the journal-then-register ordering Gate ships (a journal that
# raises must leave no standing approval) survives every wrapping by
# construction rather than by three re-implementations agreeing.
RSpec.describe Lain::Approval::Gate::Policy do
  # The whole artifact duck: a content address and its human-facing question.
  def artifact(digest: "blake3:plan", question: "Approve the epic plan? Reply approve or deny.")
    Data.define(:digest, :gate_question).new(digest:, gate_question: question)
  end

  let(:plan) { artifact }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:gate) { Lain::Approval::Gate.new(journal:, timeout: 0.5) }
  let(:queue) { Lain::Approval::SignoffQueue.new }
  # The Null Object a policy names when there is no sign-off queue in the
  # session at all. Named explicitly at every call site on purpose -- see the
  # "no policy opens a boundary it never checked" group.
  let(:drained) { described_class::Drained }

  def decisions
    Lain::Journal.records(journal_io.string.lines, type: "gate_decision").to_a
  end

  def decide(policy, artifact: plan, stage: "epic_plan", epic_slug: "alpha")
    Sync { policy.decide(artifact, gate:, stage:, epic_slug:) }
  end

  # The ask_human-shaped duck the Interactive policy delegates to.
  def scripted_asker(&resolver)
    Object.new.tap do |asker|
      asker.define_singleton_method(:ask) do |question|
        Lain::Promise.new.tap { |promise| yield(promise, question) }
      end
    end
  end

  describe "the seam every policy answers" do
    it "refuses to decide from the abstract base -- a policy without a surface is not one" do
      expect { decide(described_class.new(queue: drained)) }.to raise_error(NotImplementedError, /surface/)
    end

    it "labels each policy with the durable NAME its own subclass declares" do
      names = [described_class::Interactive.new(asker: scripted_asker { |p, _q| p }, queue: drained),
               described_class::HandsOff.new(queue: drained),
               described_class::Deferred.new(queue:)].map(&:name)

      expect(names).to eq(%w[interactive hands_off deferred])
    end

    it "keeps the deferred label and the queue's fold discriminator the same string" do
      expect(described_class::Deferred::NAME).to eq(Lain::Approval::SignoffQueue::DEFERRED_POLICY)
    end

    it "keeps the interactive label equal to the Gate's own default, so T5's path is not relabelled" do
      expect(described_class::Interactive::NAME).to eq(Lain::Approval::Gate::DEFAULT_POLICY)
    end
  end

  describe Lain::Approval::Gate::Policy::Interactive do
    def approving_asker(surface: "human")
      scripted_asker { |promise, _q| promise.resolve(Lain::Approval::Gate::Answer.approve(surface)) }
    end

    it "delegates to the asker and journals the surface that answered" do
      expect(decide(described_class.new(asker: approving_asker, queue: drained))).to be(true)

      expect(decisions.first).to include("approved" => true, "answered_by" => "human",
                                         "policy" => "interactive")
      expect(gate.approved?(plan.digest)).to be(true)
    end

    it "asks the artifact's own question verbatim" do
      asked = nil
      asker = scripted_asker do |promise, question|
        asked = question
        promise.resolve(Lain::Approval::Gate::Answer.approve("human"))
      end

      decide(described_class.new(asker:, queue: drained))

      expect(asked).to eq(plan.gate_question)
    end

    it "inherits the fail-closed clock -- silence is a denial signed by the timeout" do
      gate = Lain::Approval::Gate.new(journal:, timeout: 0.02)
      policy = described_class.new(asker: scripted_asker { |_promise, _q| nil }, queue: drained)

      approved = Sync { policy.decide(plan, gate:, stage: "research", epic_slug: "alpha") }

      expect(approved).to be(false)
      expect(decisions.first).to include("answered_by" => "timeout", "policy" => "interactive")
    end
  end

  # AC1
  describe "hands-off approves audibly" do
    subject(:policy) { described_class::HandsOff.new(queue: drained) }

    it "approves and journals answered_by hands_off under policy hands_off" do
      expect(decide(policy)).to be(true)

      expect(decisions.first).to include("approved" => true, "answered_by" => "hands_off",
                                         "policy" => "hands_off")
    end

    it "leaves a standing approval, so ensure_approved! opens" do
      decide(policy)

      expect(gate.ensure_approved!(plan)).to eq(plan.digest)
    end

    it "carries the partition keys it was decided under" do
      decide(policy, stage: "issue_plan", epic_slug: "beta")

      expect(decisions.first).to include("stage" => "issue_plan", "epic_slug" => "beta")
    end

    it "never asks anything, so it does not wait on a human" do
      expect(decide(policy)).to be(true)
      expect(decisions.first["latency"]).to be < 0.5
    end

    it "keeps Gate's reactor precondition rather than quietly relaxing it" do
      expect { policy.decide(plan, gate:, stage: "epic_plan", epic_slug: "alpha") }
        .to raise_error(Lain::Approval::Gate::NoReactor)
    end
  end

  # AC2
  describe "deferred parks without approving" do
    subject(:policy) { described_class::Deferred.new(queue:) }

    it "answers false and journals answered_by deferred, approved false" do
      expect(decide(policy)).to be(false)

      expect(decisions.first).to include("approved" => false, "answered_by" => "deferred",
                                         "policy" => "deferred")
    end

    it "parks one item for that digest and stage" do
      decide(policy, stage: "research")

      expect(queue.parked("alpha", "research").map(&:artifact_digest)).to eq([plan.digest])
    end

    it "parks the artifact's question, so the morning review reads what it is answering" do
      decide(policy)

      expect(queue.first.question).to eq(plan.gate_question)
    end

    it "still refuses ensure_approved!, so an irreversible caller cannot proceed" do
      decide(policy)

      expect(gate.approved?(plan.digest)).to be(false)
      expect { gate.ensure_approved!(plan) }.to raise_error(Lain::Approval::Gate::NotApproved)
    end

    it "parks once for a gate decided twice -- the address is the identity" do
      decide(policy)
      decide(policy)

      expect(queue.count).to eq(1)
      expect(decisions.length).to eq(2)
    end

    it "parks an edited artifact separately, because a different content address is a different gate" do
      decide(policy)
      decide(policy, artifact: artifact(digest: "blake3:plan-v2"))

      expect(queue.map(&:artifact_digest)).to eq(%w[blake3:plan blake3:plan-v2])
    end
  end

  # The ruling this card inherits: Gate journals BEFORE it registers, and a
  # policy that wraps #call must not undo that ordering.
  describe "the journal-then-register ordering survives the wrapping" do
    let(:journal) { Object.new.tap { |j| j.define_singleton_method(:record) { |_entry| raise IOError, "disk full" } } }

    it "leaves no standing approval when the hands-off journal write raises" do
      expect { decide(described_class::HandsOff.new(queue: drained)) }.to raise_error(IOError)

      expect(gate.approved?(plan.digest)).to be(false)
      expect { gate.ensure_approved!(plan) }.to raise_error(Lain::Approval::Gate::NotApproved)
    end

    it "parks nothing when the deferral's own journal write raises -- the queue is the journal's fold" do
      expect { decide(described_class::Deferred.new(queue:)) }.to raise_error(IOError)

      expect(queue.to_a).to be_empty
    end
  end

  # The stage-boundary rule, reached through the seam that actually runs. A rule
  # only Epic::Stage could invoke would be a safety spine nothing walks: every
  # policy checks it before the gate is asked anything, so no gate opens across
  # an undrained earlier partition of its own epic.
  describe "no policy opens a gate across an undrained earlier partition" do
    def park_research(epic_slug: "alpha")
      queue.park(artifact_digest: "blake3:research", epic_slug:, stage: "research",
                 question: "Approve the research?")
    end

    it "refuses a deferred gate at epic_plan while alpha's research is parked" do
      park_research

      expect { decide(described_class::Deferred.new(queue:), stage: "epic_plan", epic_slug: "alpha") }
        .to raise_error(Lain::Epic::StageBlocked, /alpha.*research/m)
    end

    it "refuses a HANDS-OFF gate too -- an unattended run is exactly what must not skip the boundary" do
      park_research

      expect { decide(described_class::HandsOff.new(queue:), stage: "epic_plan", epic_slug: "alpha") }
        .to raise_error(Lain::Epic::StageBlocked)
    end

    it "refuses an interactive gate too, so the rule is the seam's and not one policy's" do
      park_research
      policy = described_class::Interactive.new(asker: scripted_asker { |p, _q| p }, queue:)

      expect { decide(policy, stage: "epic_plan", epic_slug: "alpha") }
        .to raise_error(Lain::Epic::StageBlocked)
    end

    it "journals nothing and approves nothing when it refuses -- the check precedes the gate" do
      park_research

      expect { decide(described_class::HandsOff.new(queue:), stage: "epic_plan", epic_slug: "alpha") }
        .to raise_error(Lain::Epic::StageBlocked)
      expect(decisions).to be_empty
      expect(gate.approved?(plan.digest)).to be(false)
    end

    it "lets a sibling epic through -- the partition is keyed by both members" do
      park_research(epic_slug: "alpha")

      expect(decide(described_class::HandsOff.new(queue:), stage: "epic_plan", epic_slug: "beta")).to be(true)
    end

    it "lets the SAME stage through -- a gate opening here is what will park here" do
      park_research

      expect(decide(described_class::HandsOff.new(queue:), stage: "research", epic_slug: "alpha")).to be(true)
    end

    it "opens once the earlier partition is drained" do
      park_research
      queue.drain(artifact_digest: "blake3:research", epic_slug: "alpha", stage: "research")

      expect(decide(described_class::HandsOff.new(queue:), stage: "epic_plan", epic_slug: "alpha")).to be(true)
    end

    it "refuses a stage name outside the closed set rather than gating on a partition nothing writes" do
      expect { decide(described_class::HandsOff.new(queue:), stage: "qa") }
        .to raise_error(Lain::Epic::UnknownStage, /qa/)
    end

    it "requires the queue to be named -- a policy silently built without one opens every boundary" do
      expect { described_class::HandsOff.new }.to raise_error(ArgumentError, /queue/)
    end

    it "opts out only by naming Drained, which answers every partition drained" do
      park_research

      expect(drained.drained?("alpha", "research")).to be(true)
      expect(decide(described_class::HandsOff.new(queue: drained), stage: "epic_plan")).to be(true)
    end
  end

  # AC3. The rule itself, as the ONE object that owns it. It was written twice
  # -- here on the policy seam and again inside Gate::Adjudicator, which is not
  # a Policy and never reaches #decide -- and two copies of a safety rule can
  # drift. Every caller now goes through this object, so the rule has a single
  # call site.
  describe Lain::Approval::Gate::Policy::Boundary do
    def park_research(epic_slug: "alpha")
      queue.park(artifact_digest: "blake3:research", epic_slug:, stage: "research",
                 question: "Approve the research?")
    end

    it "opens a stage whose earlier partitions are drained, answering the stage itself" do
      expect(described_class.new(queue).ensure_open!("epic_plan", epic_slug: "alpha"))
        .to eq(Lain::Epic::Stage.new("epic_plan"))
    end

    it "refuses a stage whose earlier partition of the same epic still holds, naming both" do
      park_research

      expect { described_class.new(queue).ensure_open!("epic_plan", epic_slug: "alpha") }
        .to raise_error(Lain::Epic::StageBlocked, /alpha.*research/m)
    end

    it "scopes the refusal to one epic, so concurrent epics stay independent" do
      park_research(epic_slug: "alpha")

      expect(described_class.new(queue).ensure_open!("epic_plan", epic_slug: "beta"))
        .to eq(Lain::Epic::Stage.new("epic_plan"))
    end

    it "refuses a stage outside the closed set rather than gating on a partition nothing writes" do
      expect { described_class.new(queue).ensure_open!("qa", epic_slug: "alpha") }
        .to raise_error(Lain::Epic::UnknownStage, /qa/)
    end

    it "opens everything when NAMED the Drained null object" do
      park_research

      expect(described_class.new(Lain::Approval::Gate::Policy::Drained).ensure_open!("epic_plan", epic_slug: "alpha"))
        .to eq(Lain::Epic::Stage.new("epic_plan"))
    end
  end
end
