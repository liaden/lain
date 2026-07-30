# frozen_string_literal: true

require "stringio"

# Epic::Submission binds one artifact to one stage of an epic's pipeline: the
# gate's whole duck (#digest, #gate_question), spelled out for the four shapes
# the pipeline actually produces. Prose artifacts (research, issue_plan) digest
# their bytes through Canonical.digest, so an edited word is a different,
# un-approved address. epic_plan reuses Epic::Graph#digest instead, so a
# reformatted-but-unchanged plan keeps its standing approval.
#
# #digest is (stage, slug, artifact) composed together (Joel's ruling on the
# T1 review round-2 BLOCKER), not the artifact's content address alone --
# Approval::Gate's registry is keyed on #digest alone, so content-address-only
# would let epic alpha's approval silently open epic beta's identical plan,
# or a research sign-off silently open an issue_plan resubmitting the same
# words. #content_digest stays public for the raw content address (still
# equal to Epic::Graph#digest for an epic_plan submission).
RSpec.describe Lain::Epic::Submission do
  def issue(id, **overrides) = Lain::Epic::Issue.new(id:, title: "Issue #{id}", **overrides)

  def three_issue_graph
    Lain::Epic::Graph.new(issues: [issue("a"), issue("b"), issue("c")])
  end

  describe "a submission answers the gate duck" do
    let(:graph) { three_issue_graph }
    let(:submission) { described_class.epic_plan(graph:, slug: "demo") }
    let(:journal_io) { StringIO.new }
    let(:journal) { Lain::Journal.new(io: journal_io) }
    let(:gate) { Lain::Approval::Gate.new(journal:) }

    def approve_asker(surface: "human")
      Object.new.tap do |asker|
        asker.define_singleton_method(:ask) do |_question|
          Lain::Promise.new.tap { |promise| promise.resolve(Lain::Approval::Gate::Answer.approve(surface)) }
        end
      end
    end

    def decisions
      Lain::Journal.records(journal_io.string.lines, type: "gate_decision").to_a
    end

    # AC1, SUPERSEDED wording: the card's literal AC1 says "ensure_approved!
    # returns the graph digest". Joel's ruling on the round-2 BLOCKER makes
    # #digest (stage, slug, artifact) composed together, so ensure_approved!
    # now returns the SUBMISSION digest, which equals the graph digest only
    # incidentally never structurally. Recorded on the plan doc too.
    it "lets ensure_approved! return the submission digest once Gate#call approves it" do
      Sync { gate.call(submission, asker: approve_asker, stage: "epic_plan", epic_slug: "demo") }

      expect(gate.ensure_approved!(submission)).to eq(submission.digest)
    end

    it "keeps content_digest as the graph's own content address, distinct from the gate digest" do
      expect(submission.content_digest).to eq(graph.digest)
      expect(submission.digest).not_to eq(graph.digest)
    end

    it "journals a gate_decision carrying stage epic_plan and slug demo" do
      Sync { gate.call(submission, asker: approve_asker, stage: "epic_plan", epic_slug: "demo") }

      decision = decisions.first
      expect(decision.values_at("stage", "epic_slug")).to eq(%w[epic_plan demo])
    end
  end

  # T1 review round 2, the HELD blocker Joel ruled on: #digest used to answer
  # only the artifact's content address, so the Gate's digest-keyed registry
  # (which knows nothing of stage/slug -- that is the whole point of naming
  # them separately on GateDecision) could not tell epic alpha's plan from
  # epic beta's identical one, or a research doc from an issue_plan
  # resubmitting the same words. Converted from probe_t1.rb P3.
  describe "the digest binds stage and slug, not just the artifact" do
    it "differs for the same graph submitted under two different epic slugs" do
      alpha = described_class.epic_plan(graph: three_issue_graph, slug: "alpha")
      beta = described_class.epic_plan(graph: three_issue_graph, slug: "beta")

      expect(alpha.content_digest).to eq(beta.content_digest) # same content, by construction
      expect(alpha.digest).not_to eq(beta.digest)
    end

    it "differs for the same text submitted as research versus as an issue_plan" do
      research = described_class.research(text: "same words", slug: "demo")
      plan = described_class.issue_plan(text: "same words", slug: "demo", issue_id: "T1")

      expect(research.content_digest).to eq(plan.content_digest) # same content, by construction
      expect(research.digest).not_to eq(plan.digest)
    end

    describe "at the Gate, where the bleed used to actually matter" do
      let(:journal) { Lain::Journal.new(io: StringIO.new) }
      let(:gate) { Lain::Approval::Gate.new(journal:) }

      def approve_asker(surface: "human")
        Object.new.tap do |asker|
          asker.define_singleton_method(:ask) do |_question|
            Lain::Promise.new.tap { |promise| promise.resolve(Lain::Approval::Gate::Answer.approve(surface)) }
          end
        end
      end

      it "does not let approving epic alpha's plan open epic beta's identical plan" do
        alpha = described_class.epic_plan(graph: three_issue_graph, slug: "alpha")
        beta = described_class.epic_plan(graph: three_issue_graph, slug: "beta")
        Sync { gate.call(alpha, asker: approve_asker, stage: "epic_plan", epic_slug: "alpha") }

        expect(gate.approved?(beta.digest)).to be(false)
        expect { gate.ensure_approved!(beta) }.to raise_error(Lain::Approval::Gate::NotApproved)
      end

      it "does not let approving research open an issue_plan resubmitting the same words" do
        research = described_class.research(text: "same words", slug: "demo")
        plan = described_class.issue_plan(text: "same words", slug: "demo", issue_id: "T1")
        Sync { gate.call(research, asker: approve_asker, stage: "research", epic_slug: "demo") }

        expect(gate.approved?(plan.digest)).to be(false)
      end
    end
  end

  # T1 review round 3, fix 3: Gate.from_journal (landed on main while this
  # card was in review) folds journaled gate_decision records back into
  # @approved and compares against a FRESHLY computed artifact.digest -- so
  # #digest is now a cross-session replay key, not merely an in-process one.
  # A literal expected value here is what makes a future Canonical change
  # that silently moves the digest fail loudly, instead of quietly orphaning
  # every already-journaled approval on the next process's replay.
  describe "#digest is a stable, literal value for a fixed (stage, slug, artifact)" do
    it "matches one hardcoded digest for stage research, slug demo, artifact blake3:abc" do
      submission = described_class.new(stage: "research", slug: "demo", content_digest: "blake3:abc",
                                       fact: "1 bytes")

      expect(submission.digest).to eq("blake3:73eb704a23cea63e1a24793f89ec8a4da2bcf188d04a3174a5344dfffa9d133d")
    end
  end

  describe "epic_plan digest stability" do
    # AC2: two markdown renderings that PARSE to the same graph share a digest.
    # Constructing the graph twice from independently-ordered issue arrays
    # stands in for "two renderings": Graph itself normalizes id order, so the
    # test exercises exactly the reformatting a re-render performs.
    it "shares one digest across two graphs built from differently-ordered issues" do
      first = Lain::Epic::Graph.new(issues: [issue("a"), issue("b"), issue("c")])
      second = Lain::Epic::Graph.new(issues: [issue("c"), issue("a"), issue("b")])

      one = described_class.epic_plan(graph: first, slug: "demo")
      two = described_class.epic_plan(graph: second, slug: "demo")

      expect(one.digest).to eq(two.digest)
    end
  end

  describe "research digest sensitivity" do
    # AC3: one changed word moves the digest.
    it "differs when one word of the research text changes" do
      original = described_class.research(text: "the quick brown fox", slug: "demo")
      edited = described_class.research(text: "the slow brown fox", slug: "demo")

      expect(original.digest).not_to eq(edited.digest)
    end

    it "matches Canonical.digest of the exact bytes via content_digest" do
      submission = described_class.research(text: "hello world", slug: "demo")

      expect(submission.content_digest).to eq(Lain::Canonical.digest("hello world"))
    end
  end

  describe "gate_question" do
    it "names the stage, the slug, and the issue count for an epic_plan" do
      submission = described_class.epic_plan(graph: three_issue_graph, slug: "demo")

      expect(submission.gate_question).to include("epic_plan", "demo", "3")
    end

    it "names the stage, the slug, and the byte size for research prose" do
      text = "hello world"
      submission = described_class.research(text:, slug: "demo")

      expect(submission.gate_question).to include("research", "demo", text.bytesize.to_s)
    end

    it "names the issue for an issue_plan, plus its byte size" do
      text = "as a user I want..."
      submission = described_class.issue_plan(text:, slug: "demo", issue_id: "T7")

      expect(submission.gate_question).to include("issue_plan", "T7", text.bytesize.to_s)
    end

    it "takes an implementation's content_digest as given, rather than deriving it" do
      submission = described_class.implementation(slug: "demo", issue_id: "T7", digest: "blake3:impl")

      expect(submission.content_digest).to eq("blake3:impl")
    end

    it "names the issue for an implementation" do
      submission = described_class.implementation(slug: "demo", issue_id: "T7", digest: "blake3:impl")

      expect(submission.gate_question).to include("implementation", "T7")
    end
  end

  describe "construction" do
    it "is deeply frozen, so a submission can cross a Ractor boundary" do
      submission = described_class.research(text: "hello", slug: "demo")

      expect(Ractor.shareable?(submission)).to be(true)
    end

    it "refuses a blank slug, naming the field" do
      expect { described_class.research(text: "hello", slug: "") }
        .to raise_error(ArgumentError, /slug/)
    end
  end

  # Review round 2 (T1 REQUEST-CHANGES), fix 2: a blank issue_id used to sail
  # through into fact ("issue " is non-blank prose), so a human ended up asked
  # to approve an unnamed issue. Found by probe_t1.rb P4.
  describe "issue_id validation" do
    it "refuses a nil issue_id on issue_plan, naming the field" do
      expect { described_class.issue_plan(text: "x", slug: "demo", issue_id: nil) }
        .to raise_error(ArgumentError, /issue_id/)
    end

    it "refuses a blank issue_id on issue_plan" do
      expect { described_class.issue_plan(text: "x", slug: "demo", issue_id: "") }
        .to raise_error(ArgumentError, /issue_id/)
    end

    it "refuses a nil issue_id on implementation, naming the field" do
      expect { described_class.implementation(slug: "demo", issue_id: nil, digest: "blake3:x") }
        .to raise_error(ArgumentError, /issue_id/)
    end
  end

  # Fix 3: nil text raised an unnamed NoMethodError three frames down inside
  # #bytesize; a Hash/Integer/Symbol text passed Canonical.digest (which
  # canonicalizes all three) and was only accidentally stopped by that same
  # #bytesize call. Found by probe_t1.rb P4.
  describe "text and graph refusals" do
    it "refuses nil text on research, naming the field rather than raising NoMethodError" do
      expect { described_class.research(text: nil, slug: "demo") }
        .to raise_error(ArgumentError, /text/)
    end

    it "refuses non-String text on research" do
      expect { described_class.research(text: { "a" => 1 }, slug: "demo") }
        .to raise_error(ArgumentError, /text/)
    end

    it "refuses nil text on issue_plan" do
      expect { described_class.issue_plan(text: nil, slug: "demo", issue_id: "T7") }
        .to raise_error(ArgumentError, /text/)
    end

    it "refuses nil graph on epic_plan, naming the field rather than raising NoMethodError" do
      expect { described_class.epic_plan(graph: nil, slug: "demo") }
        .to raise_error(ArgumentError, /graph/)
    end

    it "refuses a non-Graph object on epic_plan" do
      expect { described_class.epic_plan(graph: { "issues" => [] }, slug: "demo") }
        .to raise_error(ArgumentError, /graph/)
    end
  end

  # T1 review round 3, fix 1: #digest canonicalizes slug (see the class
  # header), and Canonical.normalize raises on a String that cannot round-trip
  # to UTF-8. Unchecked, that turned #digest from TOTAL (a stored, validated
  # String, same as every other Submission field) into a method that raises
  # deep inside Approval::Gate#call -- its first line is `artifact.digest`,
  # three frames before the asker is ever reached. A slug plausibly arrives
  # via a Linux directory name (Epic::Home), which is arbitrary bytes, not
  # guaranteed UTF-8. Refusing it at construction restores totality and moves
  # the failure to a named ArgumentError where every other bad input in this
  # file already lands.
  describe "slug must be canonicalizable, so #digest stays total" do
    it "refuses an invalid-UTF-8 slug at construction, naming the field" do
      expect { described_class.research(text: "hello", slug: "\xff".b) }
        .to raise_error(ArgumentError, /slug/)
    end

    it "never reaches Gate#call with a slug #digest cannot hash" do
      # Before this fix, .research(text:, slug: "\xff".b) constructed fine and
      # only raised later, three frames inside Gate#call's `artifact.digest`.
      # Now the bad slug never survives construction to reach the Gate at all.
      expect { described_class.epic_plan(graph: three_issue_graph, slug: "\xff".b) }
        .to raise_error(ArgumentError, /slug/)
    end
  end

  # Fix 4: digest only got presence:, so anything answering #dup/#freeze --
  # a Hash, an Array, an Integer -- was accepted. A Hash/Array digest holds
  # mutable Strings inside a shallow freeze, which breaks the Ractor.shareable?
  # promise this class's header makes. Found by probe_t1.rb P1/P4.
  describe "digest must be a String" do
    it "refuses a Hash digest on implementation" do
      expect { described_class.implementation(slug: "demo", issue_id: "T7", digest: { "a" => "b" }) }
        .to raise_error(ArgumentError, /digest/)
    end

    it "refuses an Array digest on implementation" do
      expect { described_class.implementation(slug: "demo", issue_id: "T7", digest: ["blake3:x"]) }
        .to raise_error(ArgumentError, /digest/)
    end

    it "refuses an Integer digest on implementation" do
      expect { described_class.implementation(slug: "demo", issue_id: "T7", digest: 7) }
        .to raise_error(ArgumentError, /digest/)
    end

    it "stays Ractor-shareable for the String digest every constructor actually produces" do
      submission = described_class.implementation(slug: "demo", issue_id: "T7", digest: "blake3:impl")

      expect(Ractor.shareable?(submission)).to be(true)
    end
  end

  # Fix 5, first half: the card requires BOTH directions of the epic_plan law
  # -- reformatting must NOT move the digest (pinned above) and a real change
  # to the graph MUST. All three were verified true by the panel; only
  # stability had a spec before this round.
  describe "epic_plan digest sensitivity" do
    it "moves when an issue is added" do
      base = described_class.epic_plan(graph: three_issue_graph, slug: "demo")
      grown = Lain::Epic::Graph.new(issues: [issue("a"), issue("b"), issue("c"), issue("d")])

      expect(described_class.epic_plan(graph: grown, slug: "demo").digest).not_to eq(base.digest)
    end

    it "moves when an issue's title changes" do
      base = described_class.epic_plan(graph: three_issue_graph, slug: "demo")
      retitled = Lain::Epic::Graph.new(issues: [issue("a"), issue("b"), issue("c", title: "Issue c, renamed")])

      expect(described_class.epic_plan(graph: retitled, slug: "demo").digest).not_to eq(base.digest)
    end

    it "moves when a blocks edge is added" do
      base = described_class.epic_plan(graph: three_issue_graph, slug: "demo")
      blocked = Lain::Epic::Graph.new(issues: [issue("a"), issue("b", blocks: %w[a]), issue("c")])

      expect(described_class.epic_plan(graph: blocked, slug: "demo").digest).not_to eq(base.digest)
    end
  end

  # Fix 5, second half: the design note argues stage is worth re-validating
  # here even though every call site is a hardcoded literal, because a fifth
  # constructor (or a direct .new/#with) is the one thing that could still
  # reach an unknown stage. That argument had no spec pinning it.
  describe "the closed stage set, even off the four constructors" do
    it "refuses an unknown stage passed directly to .new" do
      expect { described_class.new(stage: "nonsense", slug: "demo", content_digest: "blake3:x", fact: "1 bytes") }
        .to raise_error(ArgumentError, /stage/)
    end

    it "refuses an unknown stage reached through Data#with, which re-enters the constructor" do
      valid = described_class.research(text: "hello", slug: "demo")

      expect { valid.with(stage: "nonsense") }.to raise_error(ArgumentError, /stage/)
    end
  end

  # Fix 7: gate_question is what Policy/Adjudicator journal, and it was the
  # only thing a shareable Submission handed back mutable -- mutating the
  # returned String used to silently succeed with no state leak (Submission
  # itself stayed correct), but a shareable value producing a mutable String
  # is still the wrong shape to ship. Found by probe_t1.rb P5.
  describe "gate_question is itself frozen" do
    it "returns a frozen String" do
      submission = described_class.research(text: "hello", slug: "demo")

      expect(submission.gate_question).to be_frozen
    end
  end

  # Fix 8: slug.inspect is a JSON-safety property, not a formatting choice --
  # Policy/Adjudicator journal gate_question into NDJSON, so a slug carrying a
  # literal newline must not break the line. Originally found by probe_t1b.rb.
  describe "gate_question stays JSON-safe for a hostile slug" do
    it "round-trips through JSON.generate when the slug carries a literal newline" do
      submission = described_class.research(text: "hello", slug: "a\nb")

      expect { JSON.generate({ "q" => submission.gate_question }) }.not_to raise_error
    end
  end

  # Judgment call (finding 6, argued in .handback-T1.md rather than changed):
  # empty prose and an empty graph both construct. "0 bytes of research" and
  # "0 issues" are honest, degenerate FACTS about a real artifact, not
  # malformed input -- whether either is worth a human's approval is a
  # Policy/UX question this constructor is not positioned to answer. Pinned
  # so a future change to that call is a deliberate spec edit, not a silent
  # behavior drift.
  describe "empty prose and empty graphs construct rather than refuse (deliberate, see finding 6)" do
    it "builds a research submission over empty text" do
      submission = described_class.research(text: "", slug: "demo")

      expect(submission.gate_question).to include("0 bytes")
    end

    it "builds an epic_plan submission over an empty graph" do
      submission = described_class.epic_plan(graph: Lain::Epic::Graph.new(issues: []), slug: "demo")

      expect(submission.gate_question).to include("0 issues")
    end
  end
end
