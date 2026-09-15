# frozen_string_literal: true

# Epic::Stage is the closed ordered set an epic walks: research -> epic_plan ->
# issue_plan -> implementation. It is a value object, so an unknown name fails at
# construction rather than as a missing branch three cards later, and it owns the
# STAGE-BOUNDARY rule: a stage may only open once every earlier stage's sign-off
# partition is drained AND carries an approval, per epic.
RSpec.describe Lain::Epic::Stage do
  let(:queue) { Lain::Approval::SignoffQueue.new }

  def stage(name) = described_class.new(name)

  def park(epic_slug:, stage:, digest: "blake3:plan", **scope)
    queue.park(artifact_digest: digest, epic_slug:, stage:, question: "Approve?", **scope)
  end

  # Folded the way a journaled sign-off is, since a verdict reaches the queue
  # only as a decision record.
  def decide(approved:, epic_slug:, stage:, digest:, **scope)
    queue.apply(Lain::Approval::GateDecision.new(artifact_digest: digest, epic_slug:, stage:, approved:,
                                                 answered_by: "human", policy: "signoff", latency: 1.0, **scope)
                                            .to_journal)
  end

  def approve(digest: "blake3:approved", **address) = decide(approved: true, digest:, **address)
  def deny(digest: "blake3:denied", **address) = decide(approved: false, digest:, **address)

  # Every stage up to and including `last`; an issue-scoped one for that issue.
  def approve_through(last, epic_slug: "alpha", issue_id: nil)
    stage(last).preceding.push(stage(last)).each do |earlier|
      approve(epic_slug:, stage: earlier.name, issue_id: (issue_id if earlier.issue_scoped?))
    end
  end

  describe "the closed set" do
    it "is exactly the four stages, in pipeline order" do
      expect(Lain::Epic::STAGES).to eq(%w[research epic_plan issue_plan implementation])
    end

    it "enumerates one Stage per name through .all, in the same order" do
      expect(described_class.all.map(&:name)).to eq(Lain::Epic::STAGES)
    end

    # Pinned WHOLE, not by a loose scan for the offender and the endpoints.
    # `cli/epic_submit.rb` is the first thing `lain epic submit STAGE` does with
    # argv and this error renders as a one-line message at the terminal, so the
    # wording is a user-facing surface -- and a scan that only demands "qa" and
    # the two endpoints appear SOMEWHERE let a rewrite silently open the message
    # with the carrier's attribute name, a word the human never typed. The
    # `"<attribute> <message>"` join means `name` leads whatever is written
    # here; the assertion is anchored so the rest has to go on reading as a
    # sentence after it.
    it "refuses an unknown name loudly, naming the closed set first and the offender last" do
      expect { stage("qa") }.to raise_error(
        Lain::Epic::UnknownStage,
        /\Aname must be one of research -> epic_plan -> issue_plan -> implementation, got "qa"\z/
      )
    end

    it "refuses an empty name -- a blank stage is the one partition key nothing can match back" do
      expect { stage("") }.to raise_error(Lain::Epic::UnknownStage)
    end

    it "accepts a Symbol, since the name is stored as the journaled String" do
      expect(stage(:research).name).to eq("research")
    end

    it "is Ractor-shareable (an interned String and nothing else)" do
      expect(stage(+"research")).to be_deeply_frozen
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
        .to raise_error(Lain::Error, /implementation/)
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

  describe "deferral never crosses a stage boundary within an epic" do
    it "raises naming the epic and the undrained earlier stage" do
      approve(epic_slug: "alpha", stage: "research")
      park(epic_slug: "alpha", stage: "research")

      expect { stage("epic_plan").ensure_open!(queue, epic_slug: "alpha") }
        .to raise_error(Lain::Epic::StageBlocked, /alpha.*research still holds sign-offs parked/m)
    end

    it "names every undrained earlier stage, not only the first" do
      park(epic_slug: "alpha", stage: "research")
      park(epic_slug: "alpha", stage: "epic_plan", digest: "blake3:issues")

      expect { stage("implementation").ensure_open!(queue, epic_slug: "alpha") }
        .to raise_error(Lain::Epic::StageBlocked, /research.*epic_plan/m)
    end

    it "ignores the stage's OWN partition -- a gate opening here is what will park there" do
      approve(epic_slug: "alpha", stage: "research")
      park(epic_slug: "alpha", stage: "epic_plan")

      expect(stage("epic_plan").ensure_open!(queue, epic_slug: "alpha")).to eq(stage("epic_plan"))
    end

    it "ignores LATER stages, which cannot have run yet" do
      park(epic_slug: "alpha", stage: "implementation")

      expect { stage("research").ensure_open!(queue, epic_slug: "alpha") }.not_to raise_error
    end

    it "opens once the earlier partition's deferral is answered by an approval" do
      park(epic_slug: "alpha", stage: "research")
      approve(epic_slug: "alpha", stage: "research", digest: "blake3:plan")

      expect { stage("epic_plan").ensure_open!(queue, epic_slug: "alpha") }.not_to raise_error
    end

    # An earlier approval of other bytes is not an answer to what is parked now.
    it "still blocks while a later deferral is parked beside an earlier approval" do
      approve(epic_slug: "alpha", stage: "research", digest: "blake3:first")
      park(epic_slug: "alpha", stage: "research", digest: "blake3:revised")

      expect { stage("epic_plan").ensure_open!(queue, epic_slug: "alpha") }
        .to raise_error(Lain::Epic::StageBlocked, /research still holds sign-offs parked/)
    end

    it "opens the first stage unconditionally -- it has no earlier partition to drain" do
      park(epic_slug: "alpha", stage: "research")

      expect { stage("research").ensure_open!(queue, epic_slug: "alpha") }.not_to raise_error
    end
  end

  # Drained is the absence of a parked record, which a stage nobody ever
  # submitted satisfies too. So each earlier stage must also carry an approval.
  describe "an earlier stage needs positive approval evidence" do
    it "refuses a stage whose earlier stage was never decided, naming it as not approved" do
      expect { stage("epic_plan").ensure_open!(queue, epic_slug: "alpha") }
        .to raise_error(Lain::Epic::StageBlocked, /"alpha" cannot open its epic_plan stage -- research not approved/)
    end

    it "names every earlier stage never approved" do
      approve(epic_slug: "alpha", stage: "research")

      expect { stage("implementation").ensure_open!(queue, epic_slug: "alpha", issue_id: "a") }
        .to raise_error(Lain::Epic::StageBlocked, /epic_plan, issue_plan not approved/)
    end

    it "does not count a denial as approval" do
      deny(epic_slug: "alpha", stage: "research", digest: "blake3:no")

      expect { stage("epic_plan").ensure_open!(queue, epic_slug: "alpha") }
        .to raise_error(Lain::Epic::StageBlocked, /research not approved/)
    end

    # The partition's newest verdict is what the stage stands on: an approval
    # of the first draft says nothing once the resubmitted one is denied.
    it "blocks once a resubmitted research is denied after its first draft was approved" do
      approve(epic_slug: "alpha", stage: "research", digest: "blake3:v1")
      deny(epic_slug: "alpha", stage: "research", digest: "blake3:v2")

      expect { stage("epic_plan").ensure_open!(queue, epic_slug: "alpha") }
        .to raise_error(Lain::Epic::StageBlocked, /research not approved/)
    end

    it "opens again once research is re-approved after that denial" do
      approve(epic_slug: "alpha", stage: "research", digest: "blake3:v1")
      deny(epic_slug: "alpha", stage: "research", digest: "blake3:v2")
      approve(epic_slug: "alpha", stage: "research", digest: "blake3:v3")

      expect(stage("epic_plan").ensure_open!(queue, epic_slug: "alpha")).to eq(stage("epic_plan"))
    end

    it "names a parked stage as parked and a never-approved one as not approved, in one refusal" do
      park(epic_slug: "alpha", stage: "research")

      expect { stage("issue_plan").ensure_open!(queue, epic_slug: "alpha", issue_id: "a") }
        .to raise_error(Lain::Epic::StageBlocked, /research still holds sign-offs parked.*epic_plan not approved/m)
    end

    it "opens once every earlier stage is approved" do
      approve_through("issue_plan", issue_id: "a")

      expect(stage("implementation").ensure_open!(queue, epic_slug: "alpha", issue_id: "a"))
        .to eq(stage("implementation"))
    end

    it "reads an epic-wide approval as every issue's" do
      approve_through("epic_plan")

      expect(stage("issue_plan").ensure_open!(queue, epic_slug: "alpha", issue_id: "b")).to eq(stage("issue_plan"))
    end

    it "wants the issue's OWN plan approved before its implementation opens" do
      approve_through("issue_plan", issue_id: "a")

      expect { stage("implementation").ensure_open!(queue, epic_slug: "alpha", issue_id: "b") }
        .to raise_error(Lain::Epic::StageBlocked, /issue "b".*issue_plan not approved/)
    end
  end

  # research and epic_plan are the epic's own documents; an issue's plan and
  # its implementation are ONE issue's work, so a boundary between two
  # issue-scoped stages is crossed per issue.
  describe "issue-scoped stages" do
    it "names issue_plan and implementation as the stages tracked per issue" do
      expect(described_class.all.select(&:issue_scoped?).map(&:name)).to eq(%w[issue_plan implementation])
    end

    # Scenario: a parked issue does not block a sibling
    it "opens b's implementation while a's issue_plan is parked" do
      approve_through("issue_plan", issue_id: "b")
      park(epic_slug: "alpha", stage: "issue_plan", issue_id: "a")

      expect(stage("implementation").ensure_open!(queue, epic_slug: "alpha", issue_id: "b"))
        .to eq(stage("implementation"))
    end

    it "still blocks a's own implementation, naming the issue" do
      park(epic_slug: "alpha", stage: "issue_plan", issue_id: "a")

      expect { stage("implementation").ensure_open!(queue, epic_slug: "alpha", issue_id: "a") }
        .to raise_error(Lain::Epic::StageBlocked, /alpha.*issue "a".*issue_plan/m)
    end

    it "blocks every issue while an epic-wide stage still holds a sign-off" do
      park(epic_slug: "alpha", stage: "epic_plan")

      expect { stage("implementation").ensure_open!(queue, epic_slug: "alpha", issue_id: "b") }
        .to raise_error(Lain::Epic::StageBlocked, /epic_plan/)
    end

    # A park written before gates named their issue holds every issue's
    # boundary; the refusal says which one, and why it reaches this issue.
    it "names a park that names no issue, by digest, when it holds an issue's gate" do
      park(epic_slug: "alpha", stage: "issue_plan", digest: "blake3:legacy")

      expect { stage("implementation").ensure_open!(queue, epic_slug: "alpha", issue_id: "b") }
        .to raise_error(Lain::Epic::StageBlocked, /blake3:legacy.*names no issue/m)
    end

    it "reads a check that names no issue as every issue's" do
      park(epic_slug: "alpha", stage: "issue_plan", issue_id: "a")

      expect { stage("implementation").ensure_open!(queue, epic_slug: "alpha") }
        .to raise_error(Lain::Epic::StageBlocked, /issue_plan/)
    end
  end

  describe "epics do not block each other's boundaries" do
    it "opens beta's epic_plan gate while alpha's research partition is still parked" do
      approve(epic_slug: "beta", stage: "research")
      park(epic_slug: "alpha", stage: "research")

      expect { stage("epic_plan").ensure_open!(queue, epic_slug: "beta") }.not_to raise_error
    end

    it "opens alpha's epic_plan gate while beta has submitted nothing at all" do
      approve(epic_slug: "alpha", stage: "research")

      expect { stage("epic_plan").ensure_open!(queue, epic_slug: "alpha") }.not_to raise_error
    end

    it "lets no epic's approval vouch for another's stage" do
      approve(epic_slug: "beta", stage: "research")

      expect { stage("epic_plan").ensure_open!(queue, epic_slug: "alpha") }
        .to raise_error(Lain::Epic::StageBlocked, /"alpha".*research not approved/)
    end

    it "still blocks alpha, so the partition is keyed by BOTH members" do
      approve(epic_slug: "alpha", stage: "research")
      approve(epic_slug: "beta", stage: "research")
      park(epic_slug: "alpha", stage: "research")
      stage("epic_plan").ensure_open!(queue, epic_slug: "beta")

      expect { stage("epic_plan").ensure_open!(queue, epic_slug: "alpha") }
        .to raise_error(Lain::Epic::StageBlocked)
    end
  end
end
