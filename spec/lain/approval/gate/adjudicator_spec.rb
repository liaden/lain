# frozen_string_literal: true

require "async"
require "stringio"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module AdjudicatorSpecSupport
  # A {Skill::RoleSpawn} stand-in scripted PER ROLE. The adjudicator spawns two
  # different roles inside one #call -- the evidence spike and the verdict -- so
  # a single-answer stub could not tell them apart, and half of what this card
  # has to prove is that the SECOND spawn never happens without the first.
  #
  # A String answer becomes an ok {Tool::Result}; anything answering #call is
  # invoked, so a spec can hand it a raiser or an error result.
  class ScriptedRoleSpawn
    attr_reader :calls

    def initialize(answers)
      @answers = answers
      @calls = []
    end

    def call(role, context_mode, prompt)
      @calls << { role:, context_mode:, prompt: }
      answer = @answers.fetch(role) { raise ArgumentError, "no scripted answer for role #{role.inspect}" }
      answer.respond_to?(:call) ? answer.call(prompt) : Lain::Tool::Result.ok(answer)
    end

    def roles = @calls.map { |spawn| spawn[:role] }
  end
end

# Approval::Gate::Adjudicator is the spike-first attempt a deferred gate makes to
# answer itself: gather evidence with the `researcher` role, hand the question
# plus that evidence to the `gate_adjudicator` role, and act only on a bare
# one-word verdict. Every other path -- prose around the word, an unrecognized
# word, a spawn that raised, a spike that returned nothing -- lands on DEFER,
# which parks for a human and approves nothing. The safety property is that no
# route through this class reaches an approval without evidence behind it.
RSpec.describe Lain::Approval::Gate::Adjudicator do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:gate) { Lain::Approval::Gate.new(journal:, timeout: 0.5) }
  let(:queue) { Lain::Approval::SignoffQueue.new }
  let(:evidence_text) { "The plan cites Epic::Stage's closed set, which the issue graph already honours." }

  # The whole artifact duck Gate ships: a content address and its own question.
  def artifact(digest: "blake3:plan", question: "Approve the epic plan? Reply approve or deny.")
    Data.define(:digest, :gate_question).new(digest:, gate_question: question)
  end

  let(:plan) { artifact }

  def spawn_stub(researcher: evidence_text, verdict: "APPROVE")
    AdjudicatorSpecSupport::ScriptedRoleSpawn.new(researcher:, gate_adjudicator: verdict)
  end

  # The caller's answer to "how does an artifact render for a spike". There is
  # no default -- nothing maps a digest to a path -- so every construction site,
  # including this one, has to say.
  let(:brief) { ->(item) { "Gather evidence for: #{item.gate_question}" } }

  def adjudicator(spawn = spawn_stub, clock: Lain::Approval::Gate::MONOTONIC)
    described_class.new(role_spawn: spawn, gate:, queue:, journal:, brief:, clock:)
  end

  def adjudicate(subject_under_test = adjudicator, item: plan, stage: "epic_plan", epic_slug: "alpha")
    Sync { subject_under_test.call(item, stage:, epic_slug:) }
  end

  def decisions = Lain::Journal.records(journal_io.string.lines, type: "gate_decision").to_a
  def evidence_records = Lain::Journal.records(journal_io.string.lines, type: "gate_evidence").to_a

  # AC1
  describe "a clean APPROVE closes the gate with evidence" do
    it "approves the artifact" do
      expect(adjudicate).to be(true)
    end

    it "leaves a standing approval, so ensure_approved! opens" do
      adjudicate

      expect(gate.ensure_approved!(plan)).to eq(plan.digest)
    end

    it "journals answered_by gate_adjudicator -- a machine approval is never mistaken for a human one" do
      adjudicate

      expect(decisions.first).to include("approved" => true, "answered_by" => "gate_adjudicator")
    end

    it "carries the evidence digest on the decision, so the verdict names what it was reached on" do
      adjudicate

      expect(decisions.first["evidence_digest"]).to eq(Lain::Canonical.digest(evidence_text))
    end

    it "journals the evidence itself under the same content address" do
      adjudicate

      expect(evidence_records.first).to include("digest" => Lain::Canonical.digest(evidence_text),
                                                "text" => evidence_text, "artifact_digest" => plan.digest,
                                                "epic_slug" => "alpha", "stage" => "epic_plan")
    end

    it "parks nothing -- an answered gate is not awaiting anyone's sign-off" do
      adjudicate

      expect(queue.to_a).to be_empty
    end

    it "wears a terminal policy label, so the sign-off fold drains rather than parks it" do
      adjudicate

      expect(decisions.first["policy"]).not_to eq(Lain::Approval::SignoffQueue::DEFERRED_POLICY)
    end

    it "spawns the researcher first and the gate_adjudicator second, both on a fresh root" do
      spawn = spawn_stub
      adjudicate(adjudicator(spawn))

      expect(spawn.roles).to eq(%i[researcher gate_adjudicator])
      expect(spawn.calls.map { |c| c[:context_mode] }).to eq(%i[fresh fresh])
    end

    it "hands the gathered evidence to the adjudicator spawn, not just the question" do
      spawn = spawn_stub
      adjudicate(adjudicator(spawn))

      expect(spawn.calls.last[:prompt]).to include(evidence_text).and include(plan.gate_question)
    end
  end

  describe "a clean DENY is terminal too -- it settles the gate without parking it" do
    it "refuses, journals the denial, and parks nothing" do
      expect(adjudicate(adjudicator(spawn_stub(verdict: "DENY")))).to be(false)

      expect(decisions.first).to include("approved" => false, "answered_by" => "gate_adjudicator")
      expect(queue.to_a).to be_empty
      expect { gate.ensure_approved!(plan) }.to raise_error(Lain::Approval::Gate::NotApproved)
    end
  end

  # AC2
  describe "prose around the verdict is hesitation" do
    let(:hedged) { "APPROVE — because the spec says so" }

    it "does not approve" do
      expect(adjudicate(adjudicator(spawn_stub(verdict: hedged)))).to be(false)
      expect(gate.approved?(plan.digest)).to be(false)
    end

    it "parks the item with the evidence digest attached" do
      adjudicate(adjudicator(spawn_stub(verdict: hedged)))

      expect(queue.parked("alpha", "epic_plan").map(&:evidence_digest))
        .to eq([Lain::Canonical.digest(evidence_text)])
    end

    it "journals a deferred decision, so the queue stays a subset of the journal's fold" do
      adjudicate(adjudicator(spawn_stub(verdict: hedged)))

      expect(decisions.first).to include("approved" => false,
                                         "policy" => Lain::Approval::SignoffQueue::DEFERRED_POLICY)
      expect(decisions.first["evidence_digest"]).to eq(Lain::Canonical.digest(evidence_text))
    end

    it "carries the model's hesitation as the reason, so the morning review reads what it said" do
      adjudicate(adjudicator(spawn_stub(verdict: hedged)))

      expect(decisions.first["reason"]).to include(hedged)
    end

    it "rebuilds the same parked item (evidence digest included) from the journal alone" do
      adjudicate(adjudicator(spawn_stub(verdict: hedged)))
      rebuilt = Lain::Approval::SignoffQueue.from_journal(journal_io.string.lines)

      expect(rebuilt.parked("alpha", "epic_plan").map(&:evidence_digest))
        .to eq([Lain::Canonical.digest(evidence_text)])
    end

    it "treats an unrecognized single word as hesitation too" do
      adjudicate(adjudicator(spawn_stub(verdict: "MAYBE")))

      expect(queue.count).to eq(1)
      expect(gate.approved?(plan.digest)).to be(false)
    end

    it "accepts a lone lowercase verdict -- the contract is one word, not one casing" do
      expect(adjudicate(adjudicator(spawn_stub(verdict: "approve\n")))).to be(true)
    end
  end

  # AC3
  describe "no evidence, no approval" do
    let(:raiser) { ->(_prompt) { raise IOError, "the provider hung up" } }

    it "parks the item and does not approve" do
      expect(adjudicate(adjudicator(spawn_stub(researcher: raiser)))).to be(false)

      expect(queue.parked("alpha", "epic_plan").map(&:artifact_digest)).to eq([plan.digest])
      expect { gate.ensure_approved!(plan) }.to raise_error(Lain::Approval::Gate::NotApproved)
    end

    it "parks with an error note naming the failure" do
      adjudicate(adjudicator(spawn_stub(researcher: raiser)))

      expect(decisions.first["reason"]).to include("IOError").and include("the provider hung up")
    end

    it "never spawns the adjudicator -- there is nothing to adjudicate ON" do
      spawn = spawn_stub(researcher: raiser)
      adjudicate(adjudicator(spawn))

      expect(spawn.roles).to eq([:researcher])
    end

    it "parks with no evidence digest, because none was gathered" do
      adjudicate(adjudicator(spawn_stub(researcher: raiser)))

      expect(decisions.first["evidence_digest"]).to be_nil
      expect(queue.first.evidence_digest).to be_nil
    end

    it "treats an error Tool::Result as missing evidence, not as evidence" do
      spawn = spawn_stub(researcher: ->(_p) { Lain::Tool::Result.error("read_file denied") })
      adjudicate(adjudicator(spawn))

      expect(spawn.roles).to eq([:researcher])
      expect(gate.approved?(plan.digest)).to be(false)
      expect(queue.count).to eq(1)
    end

    it "journals the failed spike too, so the record shows the gate tried" do
      adjudicate(adjudicator(spawn_stub(researcher: raiser)))

      expect(evidence_records.first).to include("digest" => nil, "artifact_digest" => plan.digest)
      expect(evidence_records.first["reason"]).to include("IOError")
    end
  end

  describe "the adjudicator spawn failing is hesitation, not an approval" do
    it "parks with the evidence digest and an error note" do
      spawn = spawn_stub(verdict: ->(_p) { raise IOError, "the provider hung up again" })
      expect(adjudicate(adjudicator(spawn))).to be(false)

      expect(queue.first.evidence_digest).to eq(Lain::Canonical.digest(evidence_text))
      expect(decisions.first["reason"]).to include("IOError")
    end
  end

  describe "it inherits the gate's own fail-closed guarantees" do
    it "keeps Gate's reactor precondition rather than quietly relaxing it" do
      expect { adjudicator.call(plan, stage: "epic_plan", epic_slug: "alpha") }
        .to raise_error(Lain::Approval::Gate::NoReactor)
    end

    it "parks nothing when the decision's journal write raises -- the queue is the journal's fold" do
      exploding = Object.new
      exploding.define_singleton_method(:record) { |_entry| raise IOError, "disk full" }
      subject_under_test = described_class.new(role_spawn: spawn_stub(verdict: "MAYBE"),
                                               gate: Lain::Approval::Gate.new(journal: exploding),
                                               queue:, journal: exploding, brief:)

      expect { adjudicate(subject_under_test) }.to raise_error(IOError)
      expect(queue.to_a).to be_empty
    end

    it "refuses across an undrained earlier partition of its own epic, spawning nothing" do
      queue.park(artifact_digest: "blake3:research", epic_slug: "alpha", stage: "research",
                 question: "Approve the research?")
      spawn = spawn_stub

      expect { adjudicate(adjudicator(spawn)) }.to raise_error(Lain::Epic::StageBlocked, /alpha.*research/m)
      expect(spawn.calls).to be_empty
      expect(decisions).to be_empty
    end

    it "parks an edited artifact separately -- a different content address is a different gate" do
      adjudicate(adjudicator(spawn_stub(verdict: "MAYBE")))
      adjudicate(adjudicator(spawn_stub(verdict: "MAYBE")), item: artifact(digest: "blake3:plan-v2"))

      expect(queue.map(&:artifact_digest)).to eq(%w[blake3:plan blake3:plan-v2])
    end
  end

  # RULING 1: a default brief could only render a prompt the spike cannot act
  # on -- nothing maps a digest to a path, and `researcher` holds no tool that
  # would fail loudly about it, so it would come back with plausible prose about
  # nothing that then reads as gathered evidence.
  describe "the caller must say how an artifact renders for the spike" do
    it "refuses to be built without a brief" do
      expect { described_class.new(role_spawn: spawn_stub, gate:, queue:, journal:) }
        .to raise_error(ArgumentError, /brief/)
    end

    it "spawns the researcher with exactly the brief it was given" do
      spawn = spawn_stub
      adjudicate(adjudicator(spawn))

      expect(spawn.calls.first[:prompt]).to eq(brief.call(plan))
    end
  end

  # The panel's blocker. `Canonical.digest("")` is a perfectly real address, so a
  # nil-ness test calls an empty spike "gathered" and a bare APPROVE then closes
  # the gate on nothing. A model that returns nothing is far likelier than one
  # that raises, so the test has to be BLANKNESS.
  describe "an empty spike is missing evidence, not evidence" do
    def blank_spike(content)
      spawn = spawn_stub(researcher: ->(_p) { Lain::Tool::Result.ok(content) })
      [adjudicate(adjudicator(spawn)), spawn]
    end

    it "refuses an ok result carrying an empty string" do
      approved, spawn = blank_spike("")

      expect(approved).to be(false)
      expect(spawn.roles).to eq([:researcher])
    end

    it "refuses whitespace-only findings" do
      approved, spawn = blank_spike("  \n\t  ")

      expect(approved).to be(false)
      expect(spawn.roles).to eq([:researcher])
    end

    it "refuses content blocks that carry no text at all" do
      approved, spawn = blank_spike([{ "type" => "image", "source" => {} }])

      expect(approved).to be(false)
      expect(spawn.roles).to eq([:researcher])
    end

    it "parks with an error note and no evidence digest" do
      blank_spike("")

      expect(queue.first.evidence_digest).to be_nil
      expect(decisions.first["evidence_digest"]).to be_nil
      expect(decisions.first["reason"]).to include("no findings")
    end

    # `String#strip` is ASCII-only, so the first version of this fix left the
    # same hole behind a narrower door: a spike answering one U+00A0 was
    # content-addressed and a bare APPROVE closed the gate on an empty evidence
    # section. Reproduced end-to-end before the fix at
    # `approved=true roles=[:researcher, :gate_adjudicator] parked=0`.
    {
      "a non-breaking space (U+00A0)" => " ",
      "an ideographic space (U+3000)" => "　",
      "a figure space (U+2007)" => " ",
      "a zero-width space (U+200B)" => "​",
      "a zero-width no-break space (U+FEFF)" => "﻿",
      "a word joiner (U+2060)" => "⁠",
      "mixed unicode blanks" => " ​ 　﻿"
    }.each do |label, blank|
      it "refuses findings that are only #{label}" do
        approved, spawn = blank_spike(blank)

        expect(approved).to be(false)
        expect(spawn.roles).to eq([:researcher])
        expect(queue.count).to eq(1)
      end
    end

    it "refuses findings that survive no readable encoding at all" do
      approved, spawn = blank_spike("\xff\xfe".dup.force_encoding(Encoding::BINARY))

      expect(approved).to be(false)
      expect(spawn.roles).to eq([:researcher])
    end

    it "still accepts findings whose only ASCII is padding around real text" do
      expect(adjudicate(adjudicator(spawn_stub(researcher: " real findings​")))).to be(true)
    end

    it "refuses to build a 'gathered' record from nothing, so a later caller cannot reintroduce this" do
      expect do
        described_class::GateEvidence.gathered(" ​", { artifact_digest: "blake3:x", epic_slug: "alpha",
                                                       stage: "research", question: "q?" }, latency: 0.0)
      end.to raise_error(ArgumentError, /missing evidence/)
    end

    it "asks ONE predicate, so the producer and its canary cannot disagree about what nothing is" do
      expect(described_class::GateEvidence).to be_blank(" ​﻿")
      expect(described_class::GateEvidence).not_to be_blank(" x ")
    end

    it "journals the blank spike itself with no content address" do
      blank_spike("   ")

      expect(evidence_records.first).to include("digest" => nil, "text" => nil)
    end
  end

  # RULING 2: the shape is designed today and can never be extended. The morning
  # review is question + evidence + hesitation, and a spend the bench cannot
  # compare is a spend the bench did not measure.
  describe "the evidence record carries what a restarted review needs" do
    it "journals the gate's own question, which SignoffQueue::Item cannot recover" do
      adjudicate

      expect(evidence_records.first["question"]).to eq(plan.gate_question)
    end

    it "journals the spike's latency in seconds, measured on the injected clock" do
      ticks = [10.0, 10.5]
      adjudicate(adjudicator(spawn_stub, clock: -> { ticks.shift }))

      expect(evidence_records.first["latency"]).to eq(0.5)
    end

    it "measures a FAILED spike too -- a spawn that raised still spent the time" do
      ticks = [4.0, 4.25]
      spawn = spawn_stub(researcher: ->(_p) { raise IOError, "hung up" })
      adjudicate(adjudicator(spawn, clock: -> { ticks.shift }))

      expect(evidence_records.first["latency"]).to eq(0.25)
    end

    it "reports a real, non-negative latency off the default clock" do
      adjudicate

      expect(evidence_records.first["latency"]).to be >= 0
    end

    it "recovers question, evidence, and hesitation from the journal alone" do
      adjudicate(adjudicator(spawn_stub(verdict: "APPROVE — because the spec says so")))
      lines = journal_io.string.lines
      evidence = Lain::Journal.records(lines, type: "gate_evidence").first
      decision = Lain::Journal.records(lines, type: "gate_decision").first

      expect(evidence["question"]).to eq(plan.gate_question)
      expect(evidence["text"]).to eq(evidence_text)
      expect(decision["evidence_digest"]).to eq(evidence["digest"])
      expect(decision["reason"]).to include("because the spec says so")
    end
  end

  # RULING 3: Gate's registry is add-only, so an APPROVE followed by a DENY over
  # one digest leaves the journal's terminal record disagreeing with
  # `Gate#approved?`. SignoffQueue documents drift toward REFUSAL; this drifts
  # the other way, and this class is the first path that can re-run a gate with
  # nobody watching.
  describe "one digest gets one terminal adjudication" do
    it "refuses a second run over a digest it already approved, naming the digest" do
      adj = adjudicator
      adjudicate(adj)

      expect { adjudicate(adj) }
        .to raise_error(described_class::AlreadyDecided) { |e|
          expect(e.message).to include(plan.digest)
          expect(e.message).to include("true")
        }
    end

    it "refuses after a DENY too -- a denial is terminal, not a retry" do
      adj = adjudicator(spawn_stub(verdict: "DENY"))
      adjudicate(adj)

      expect { adjudicate(adj) }.to raise_error(described_class::AlreadyDecided, /false/)
    end

    it "refuses BEFORE spending a spawn or journaling anything" do
      adj = adjudicator
      adjudicate(adj)
      before = journal_io.string.lines.length

      expect { adjudicate(adj) }.to raise_error(described_class::AlreadyDecided)
      expect(journal_io.string.lines.length).to eq(before)
    end

    it "allows a re-run after a DEFERRAL -- a parked gate was never settled" do
      answers = %w[MAYBE APPROVE]
      spawn = AdjudicatorSpecSupport::ScriptedRoleSpawn.new(
        researcher: evidence_text, gate_adjudicator: ->(_p) { Lain::Tool::Result.ok(answers.shift) }
      )
      adj = adjudicator(spawn)

      expect(adjudicate(adj)).to be(false)
      expect(adjudicate(adj)).to be(true)
    end

    it "lets a DIFFERENT digest through -- the address is the identity" do
      adj = adjudicator
      adjudicate(adj)

      expect(adjudicate(adj, item: artifact(digest: "blake3:plan-v2"))).to be(true)
    end
  end

  # The should-fix: two of the three members that make a record joinable were
  # unguarded, and GateDecision/SignoffQueue::Partition both refuse exactly this.
  describe "the evidence guard refuses a partition key it could never match back" do
    let(:gathered) do
      lambda do |about|
        described_class::GateEvidence.gathered("findings", { artifact_digest: "blake3:x", epic_slug: "alpha",
                                                             stage: "research" }.merge(about).merge(question: "q?"),
                                               latency: 0.0)
      end
    end

    it "refuses a nil artifact digest" do
      expect { gathered.call(artifact_digest: nil) }.to raise_error(ArgumentError, /artifact/)
    end

    it "refuses a blank epic slug" do
      expect { gathered.call(epic_slug: "") }.to raise_error(ArgumentError, /epic/)
    end

    it "refuses a blank stage" do
      expect { gathered.call(stage: nil) }.to raise_error(ArgumentError, /stage/)
    end
  end

  # The nit: `reason` was capped and `text` was not, so a runaway spike wrote a
  # multi-megabyte line into an NDJSON experiment record.
  describe "a runaway spike cannot make the journal line unbounded" do
    let(:runaway) { "z" * 60_000 }

    it "caps the journaled findings" do
      adjudicate(adjudicator(spawn_stub(researcher: runaway)))

      expect(evidence_records.first["text"].length).to be < runaway.length
    end

    it "addresses the bytes it KEPT, so the digest never names text nobody has" do
      adjudicate(adjudicator(spawn_stub(researcher: runaway)))
      record = evidence_records.first

      expect(record["digest"]).to eq(Lain::Canonical.digest(record["text"]))
      expect(decisions.first["evidence_digest"]).to eq(record["digest"])
    end

    it "caps a runaway gate question the same way" do
      adjudicate(adjudicator, item: artifact(question: runaway))

      expect(evidence_records.first["question"].length).to be < runaway.length
    end
  end

  describe "the role it spawns is a sibling of auto_approver, not auto_approver itself" do
    it "names a catalog role whose template describes ARTIFACT adjudication" do
      role = Lain::Role::Catalog.fetch(described_class::ROLE)

      expect(role.name).to eq(:gate_adjudicator)
      expect(role.only).to eq(Lain::Role::Catalog.fetch(:auto_approver).only)
    end

    it "ships its own persona -- reusing the tool-call one would misdescribe every spawn" do
      template = Lain::Prompt::Slots.shipped_role_templates.fetch("gate-adjudicator")

      expect(template).to include("APPROVE").and include("DENY").and include("DEFER")
      expect(template).not_to include("A tool call is waiting on your verdict")
    end

    it "signs its decisions with the role's own name" do
      expect(described_class::SURFACE).to eq("gate_adjudicator")
      expect(described_class::SURFACE).not_to eq(Lain::Approval::AutoSurface::SURFACE)
    end
  end
end
