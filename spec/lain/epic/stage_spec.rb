# frozen_string_literal: true

# Epic::Stage is the closed ordered set an epic walks: research -> epic_plan ->
# issue_plan -> implementation. It is a value object, so an unknown name fails at
# construction rather than as a missing branch three cards later, and it owns the
# STAGE-BOUNDARY rule: a stage may only open once every earlier stage's sign-off
# partition is drained, per epic.
RSpec.describe Lain::Epic::Stage do
  let(:queue) { Lain::Approval::SignoffQueue.new }

  def stage(name) = described_class.new(name)

  def park(epic_slug:, stage:, digest: "blake3:plan")
    queue.park(artifact_digest: digest, epic_slug:, stage:, question: "Approve?")
  end

  describe "the closed set" do
    it "is exactly the four stages, in pipeline order" do
      expect(Lain::Epic::STAGES).to eq(%w[research epic_plan issue_plan implementation])
    end

    it "enumerates one Stage per name through .all, in the same order" do
      expect(described_class.all.map(&:name)).to eq(Lain::Epic::STAGES)
    end

    it "refuses an unknown name loudly, naming the offender and the closed set" do
      expect { stage("qa") }
        .to raise_error(Lain::Epic::UnknownStage, /"qa".*research.*implementation/m)
    end

    it "refuses an empty name -- a blank stage is the one partition key nothing can match back" do
      expect { stage("") }.to raise_error(Lain::Epic::UnknownStage)
    end

    it "accepts a Symbol, since the name is stored as the journaled String" do
      expect(stage(:research).name).to eq("research")
    end

    it "is Ractor-shareable (an interned String and nothing else)" do
      expect(Ractor.shareable?(stage(+"research"))).to be(true)
    end

    it "renders as its own name, so it can be passed anywhere a stage String is wanted" do
      expect(stage("epic_plan").to_s).to eq("epic_plan")
    end
  end

  describe "#next" do
    it "answers the following stage" do
      expect(stage("research").next).to eq(stage("epic_plan"))
    end

    it "walks the whole pipeline" do
      walked = Lain::Epic::STAGES.size.pred.times.inject([stage("research")]) do |stages, _|
        stages << stages.last.next
      end

      expect(walked.map(&:name)).to eq(Lain::Epic::STAGES)
    end

    it "refuses loudly at the terminal stage rather than answering nil" do
      expect { stage("implementation").next }
        .to raise_error(Lain::Epic::NoSuccessor, /implementation/)
    end

    it "answers #last? so a caller can ask before it asks for the successor" do
      expect(stage("implementation").last?).to be(true)
      expect(stage("research").last?).to be(false)
    end
  end

  describe "ordering" do
    it "compares by pipeline position, not alphabetically" do
      expect(stage("research")).to be < stage("epic_plan")
    end

    it "answers the stages before it, earliest first" do
      expect(stage("issue_plan").preceding.map(&:name)).to eq(%w[research epic_plan])
    end

    it "answers nothing before the first stage" do
      expect(stage("research").preceding).to be_empty
    end

    # Comparing blind called #index on the other operand, which String answers
    # with something else entirely -- so `stage < "epic_plan"` raised out of
    # String#index, naming neither Stage nor the comparison. Answering nil is
    # the Comparable protocol, and it lets Comparable say what happened.
    it "answers nil for a non-Stage, the incomparable protocol" do
      expect(stage("research") <=> "epic_plan").to be_nil
      expect(stage("research") <=> 3).to be_nil
    end

    it "names both sides when a comparison operator meets a non-Stage" do
      expect { stage("research") < "epic_plan" }
        .to raise_error(ArgumentError, /Lain::Epic::Stage with String/)
    end
  end

  # AC3
  describe "deferral never crosses a stage boundary within an epic" do
    it "raises naming the epic and the undrained earlier stage" do
      park(epic_slug: "alpha", stage: "research")

      expect { stage("epic_plan").ensure_open!(queue, epic_slug: "alpha") }
        .to raise_error(Lain::Epic::StageBlocked, /alpha.*research/m)
    end

    it "names every undrained earlier stage, not only the first" do
      park(epic_slug: "alpha", stage: "research")
      park(epic_slug: "alpha", stage: "epic_plan", digest: "blake3:issues")

      expect { stage("implementation").ensure_open!(queue, epic_slug: "alpha") }
        .to raise_error(Lain::Epic::StageBlocked, /research.*epic_plan/m)
    end

    it "ignores the stage's OWN partition -- a gate opening here is what will park there" do
      park(epic_slug: "alpha", stage: "epic_plan")

      expect(stage("epic_plan").ensure_open!(queue, epic_slug: "alpha")).to eq(stage("epic_plan"))
    end

    it "ignores LATER stages, which cannot have run yet" do
      park(epic_slug: "alpha", stage: "implementation")

      expect { stage("research").ensure_open!(queue, epic_slug: "alpha") }.not_to raise_error
    end

    it "opens once the earlier partition is drained" do
      park(epic_slug: "alpha", stage: "research")
      queue.drain(artifact_digest: "blake3:plan", epic_slug: "alpha", stage: "research")

      expect { stage("epic_plan").ensure_open!(queue, epic_slug: "alpha") }.not_to raise_error
    end

    it "opens the first stage unconditionally -- it has no earlier partition to drain" do
      park(epic_slug: "alpha", stage: "research")

      expect { stage("research").ensure_open!(queue, epic_slug: "alpha") }.not_to raise_error
    end
  end

  # AC4
  describe "epics do not block each other's boundaries" do
    it "opens beta's epic_plan gate while alpha's research partition is still parked" do
      park(epic_slug: "alpha", stage: "research")

      expect { stage("epic_plan").ensure_open!(queue, epic_slug: "beta") }.not_to raise_error
    end

    it "still blocks alpha, so the partition is keyed by BOTH members" do
      park(epic_slug: "alpha", stage: "research")
      stage("epic_plan").ensure_open!(queue, epic_slug: "beta")

      expect { stage("epic_plan").ensure_open!(queue, epic_slug: "alpha") }
        .to raise_error(Lain::Epic::StageBlocked)
    end
  end
end
