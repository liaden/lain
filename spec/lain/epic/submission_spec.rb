# frozen_string_literal: true

require "stringio"

# Epic::Submission binds one artifact to one stage of an epic's pipeline: the
# gate's whole duck (#digest, #gate_question), spelled out for the four shapes
# the pipeline actually produces. Research digests its bytes and an issue_plan
# its rendered issue view, so an edited word is a different, un-approved
# address. epic_plan reuses Epic::Graph#digest instead, so a
# reformatted-but-unchanged plan keeps its standing approval.
#
# #digest is (stage, slug, artifact) composed together (Joel's ruling on the
# review round-2 BLOCKER), not the artifact's content address alone --
# Epic::Gate's registry is keyed on #digest alone, so content-address-only
# would let epic alpha's approval silently open epic beta's identical plan,
# or a research sign-off silently open an issue_plan resubmitting the same
# words. #content_digest stays public for the raw content address (still
# equal to Epic::Graph#digest for an epic_plan submission).
RSpec.describe Lain::Epic::Submission do
  def issue(id, **overrides) = Lain::Epic::Issue.new(id:, title: "Issue #{id}", **overrides)

  def three_issue_graph
    Lain::Epic::Graph.new(issues: [issue("a"), issue("b"), issue("c")])
  end

  def epic_scenario
    <<~GHERKIN
      ```gherkin
      Scenario: lists every note
        Given 2 notes
        When the list runs
        Then it prints 2 lines
      ```
    GHERKIN
  end

  def added_scenario(name = "lists none when empty")
    "## Acceptance criteria\n\n```gherkin\nScenario: #{name}\n  Given no notes\n  When the list runs\n  " \
      "Then it prints nothing\n```\n"
  end

  def view(id = "a", authored: "Prose for #{id}.\n", criteria: epic_scenario, others: [issue("z", blocks: [id])])
    graph = Lain::Epic::Graph.new(issues: [issue(id, criteria:), *others])
    Lain::Epic::IssueView.new(issue: graph.fetch(id), graph:, authored:)
  end

  describe "a submission answers the gate duck" do
    let(:graph) { three_issue_graph }
    let(:submission) { described_class.epic_plan(graph:, slug: "demo") }
    let(:journal_io) { StringIO.new }
    let(:journal) { Lain::Journal.new(io: journal_io) }
    let(:gate) { Lain::Epic::Gate.new(journal:) }

    def approve_asker(surface: "human")
      Object.new.tap do |asker|
        asker.define_singleton_method(:ask) do |_question|
          Lain::Promise.new.tap { |promise| promise.resolve(Lain::Epic::Gate::Answer.approve(surface)) }
        end
      end
    end

    def decisions
      journal_records(journal_io, "gate_decision")
    end

    # SUPERSEDED wording: the card's literal criterion says "ensure_approved!
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
      expect(submission).not_to have_same_digest_as(graph)
    end

    it "journals a gate_decision carrying stage epic_plan and slug demo" do
      Sync { gate.call(submission, asker: approve_asker, stage: "epic_plan", epic_slug: "demo") }

      decision = decisions.first
      expect(decision.values_at("stage", "epic_slug")).to eq(%w[epic_plan demo])
    end
  end

  # Review round 2, the HELD blocker Joel ruled on: #digest used to answer
  # only the artifact's content address, so the Gate's digest-keyed registry
  # (which knows nothing of stage/slug -- that is the whole point of naming
  # them separately on GateDecision) could not tell epic alpha's plan from
  # epic beta's identical one, or a research doc from an issue_plan
  # resubmitting the same words. Converted from probe_t1.rb.
  describe "the digest binds stage and slug, not just the artifact" do
    it "differs for the same graph submitted under two different epic slugs" do
      alpha = described_class.epic_plan(graph: three_issue_graph, slug: "alpha")
      beta = described_class.epic_plan(graph: three_issue_graph, slug: "beta")

      expect(alpha.content_digest).to eq(beta.content_digest) # same content, by construction
      expect(alpha).not_to have_same_digest_as(beta)
    end

    it "differs for the same text submitted as research versus as an issue_plan" do
      research = described_class.research(text: view("T1").to_markdown, slug: "demo")
      plan = described_class.issue_plan(view: view("T1"), slug: "demo", issue_id: "T1")

      expect(research).not_to have_same_digest_as(plan)
    end

    describe "at the Gate, where the bleed used to actually matter" do
      let(:journal) { Lain::Journal.new(io: StringIO.new) }
      let(:gate) { Lain::Epic::Gate.new(journal:) }

      def approve_asker(surface: "human")
        Object.new.tap do |asker|
          asker.define_singleton_method(:ask) do |_question|
            Lain::Promise.new.tap { |promise| promise.resolve(Lain::Epic::Gate::Answer.approve(surface)) }
          end
        end
      end

      it "does not let approving epic alpha's plan open epic beta's identical plan" do
        alpha = described_class.epic_plan(graph: three_issue_graph, slug: "alpha")
        beta = described_class.epic_plan(graph: three_issue_graph, slug: "beta")
        Sync { gate.call(alpha, asker: approve_asker, stage: "epic_plan", epic_slug: "alpha") }

        expect(gate.approved?(beta.digest)).to be(false)
        expect { gate.ensure_approved!(beta) }.to raise_error(Lain::Epic::Gate::NotApproved)
      end

      it "does not let approving research open an issue_plan resubmitting the same words" do
        research = described_class.research(text: view("T1").to_markdown, slug: "demo")
        plan = described_class.issue_plan(view: view("T1"), slug: "demo", issue_id: "T1")
        Sync { gate.call(research, asker: approve_asker, stage: "research", epic_slug: "demo") }

        expect(gate.approved?(plan.digest)).to be(false)
      end
    end
  end

  # Review round 3, fix 3: Gate.from_journal (landed on main while this
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

  # An issue's plan is the issue as its view renders it: the issue in epic.md,
  # the authored file and the Links the graph derives. Approving it approves
  # all three, so an edit to any is a different, un-approved address.
  describe "an issue plan is the issue's view" do
    def plan(of = view)
      described_class.issue_plan(view: of, slug: "demo", issue_id: of.issue.id)
    end

    it "composes its content address from the issue's digest and the view's" do
      expect(plan.content_digest).to eq(Lain::Canonical.digest("issue" => view.issue.digest, "view" => view.digest))
    end

    # Scenario: editing the authored issue file reopens its gate
    it "moves its address when the authored file gains a scenario" do
      expect(plan.digest).not_to eq(plan(view(authored: "Prose for a.\n\n#{added_scenario}")).digest)
    end

    it "moves its address when a new edge blocks the issue" do
      expect(plan.digest).not_to eq(plan(view(others: [issue("z", blocks: ["a"]), issue("y", blocks: ["a"])])).digest)
    end

    it "moves its address when only the issue differs" do
      expect(plan.digest).not_to eq(plan(view("b")).digest)
    end

    it "keeps its address for two renders of the same issue" do
      expect(plan).to have_same_digest_as(plan(view))
    end

    it "carries the issue and the view's criteria digest for the gate decision" do
      added = view(authored: "Prose.\n\n#{added_scenario}")

      expect(plan(added)).to have_attributes(issue_id: "a", criteria_digest: added.criteria.digest)
      expect(plan(added).criteria_digest).not_to eq(added.issue.criteria_digest)
    end

    it "refuses an issue_id that is not the view's issue" do
      expect { described_class.issue_plan(view:, slug: "demo", issue_id: "b") }
        .to raise_error(ArgumentError, /issue_id "b".*issue "a"/)
    end

    it "stays deeply frozen" do
      expect(plan).to be_deeply_frozen
    end

    it "leaves the epic's own documents with neither" do
      expect(described_class.research(text: "hello", slug: "demo"))
        .to have_attributes(issue_id: nil, criteria_digest: nil)
    end
  end

  describe "epic_plan digest stability" do
    # Two markdown renderings that PARSE to the same graph share a digest.
    # Constructing the graph twice from independently-ordered issue arrays
    # stands in for "two renderings": Graph itself normalizes id order, so the
    # test exercises exactly the reformatting a re-render performs.
    it "shares one digest across two graphs built from differently-ordered issues" do
      first = Lain::Epic::Graph.new(issues: [issue("a"), issue("b"), issue("c")])
      second = Lain::Epic::Graph.new(issues: [issue("c"), issue("a"), issue("b")])

      one = described_class.epic_plan(graph: first, slug: "demo")
      two = described_class.epic_plan(graph: second, slug: "demo")

      expect(one).to have_same_digest_as(two)
    end
  end

  describe "research sources" do
    let(:journal) { Lain::Journal.new(io: StringIO.new) }
    let(:gate) { Lain::Epic::Gate.new(journal:) }
    let(:approve) do
      Object.new.tap do |asker|
        asker.define_singleton_method(:ask) do |_question|
          Lain::Promise.new.tap { |promise| promise.resolve(Lain::Epic::Gate::Answer.approve("human")) }
        end
      end
    end

    def research(sources) = described_class.research(text: "the research", slug: "demo", sources:)

    def approve!(submission) = Sync { gate.call(submission, asker: approve, stage: "research", epic_slug: "demo") }

    it "no longer stands once a source is edited after the approval" do
      approve!(research("asr" => "the fact"))

      expect(gate.approved?(research("asr" => "the fact, revised").digest)).to be(false)
    end

    it "no longer stands once a source is added after the approval" do
      approve!(research("asr" => "the fact"))

      expect(gate.approved?(research("asr" => "the fact", "tts" => "another").digest)).to be(false)
    end

    it "still stands when the same sources are submitted in another order" do
      approve!(research("asr" => "a", "tts" => "b"))

      expect(gate.approved?(research("tts" => "b", "asr" => "a").digest)).to be(true)
    end

    it "keeps the digest the research text alone always had when there are no sources" do
      expect(research({}).content_digest).to eq(Lain::Canonical.digest("the research"))
    end
  end

  describe "research digest sensitivity" do
    # One changed word moves the digest.
    it "differs when one word of the research text changes" do
      original = described_class.research(text: "the quick brown fox", slug: "demo")
      edited = described_class.research(text: "the slow brown fox", slug: "demo")

      expect(original).not_to have_same_digest_as(edited)
    end

    it "matches Canonical.digest of the exact bytes via content_digest" do
      submission = described_class.research(text: "hello world", slug: "demo")

      expect(submission.content_digest).to eq(Lain::Canonical.digest("hello world"))
    end
  end

  describe Lain::Epic::GateReply do
    def answer(words) = described_class.answer(words, surface: "human")

    def unheard = Lain::Epic::Gate::Unheard

    ["deny: the summarizer question needs a benchmark first", "no, the summarizer question needs a benchmark first",
     "n - the summarizer question needs a benchmark first"].each do |reply|
      it "reads #{reply.inspect} as the human's denial carrying the words after the denial word" do
        result = answer(reply)

        expect([result.approved?, result.surface,
                result.reason]).to eq([false, "human", "the summarizer question needs a benchmark first"])
      end
    end

    it "reads an approval with a note after a comma as the human's approval carrying the note" do
      result = answer("approve, re-signed unchanged")

      expect([result.approved?, result.surface, result.reason]).to eq([true, "human", "re-signed unchanged"])
      expect(result.verdict).to eq(Lain::Approval::Verdict::Approve.new(note: "re-signed unchanged"))
    end

    it "drops the line break a terminal read ends with" do
      expect(answer("deny: too broad\n").reason).to eq("too broad")
    end

    it "keeps every word after the denial word, a leading because included" do
      expect(answer("DENIED because X").reason).to eq("because X")
    end

    it "reads a denial word closed by a full stop as a denial with the words after it" do
      expect(answer("No. too broad").reason).to eq("too broad")
    end

    ["deny:", "deny: ", "n,"].each do |reply|
      it "reads #{reply.inspect}, a separator and nothing after it, as a reasonless denial" do
        result = answer(reply)

        expect([result.surface, result.reason]).to eq(["human", nil])
      end
    end

    it "keeps a multi-line reason's newlines" do
      expect(answer("deny:\nline2\n\napproved abc").reason).to eq("line2\n\napproved abc")
    end

    it "writes control bytes out rather than passing them on" do
      expect(answer("deny: red \e[31m and \u0000 nul").reason).to eq("red \\e[31m and \\x00 nul")
    end

    it "keeps a reason of several hundred characters whole" do
      text = Array.new(4) { |i| "#{i + 1}. #{"x" * 170}" }.join("\n")

      expect(answer("deny: #{text}").reason).to eq(text)
    end

    it "cuts a reason over the result ceiling and says how much was cut" do
      limit = Lain::Tool::Bounds::RESULT_BYTES
      reason = answer("deny: #{"x" * 100_000}").reason

      expect(reason).to eq("#{"x" * limit}\n[reason cut at #{limit} of 100000 bytes]")
    end

    it "cuts a multibyte reason on a character boundary and counts bytes in the notice" do
      limit = Lain::Tool::Bounds::RESULT_BYTES
      total = ((limit / 3) + 10) * 3
      reason = answer("deny: #{"日" * (total / 3)}").reason
      kept, notice = reason.split("\n[reason cut at ")

      expect(reason).to be_valid_encoding
      expect([kept.bytesize <= limit, notice]).to eq([true, "#{kept.bytesize} of #{total} bytes]"])
    end

    it "keeps a bare denial reasonless" do
      expect(answer("Deny.").reason).to be_nil
    end

    it "keeps the reason's own case and punctuation" do
      expect(answer("deny: Split M3.").reason).to eq("Split M3.")
    end

    it "denies a blank reply, as the prompt's cue says" do
      expect([answer("  \n").approved?, answer("  \n").surface]).to eq([false, "human"])
    end

    it "denies the end of input as nobody's answer" do
      expect(answer(nil).surface).to eq(described_class::EOF)
    end

    ["yes but trim the scope", "approve it", "nothing to add", "lgtm", "holding on", "waiter"].each do |reply|
      it "hears #{reply.inspect} as no verdict at all, carrying the words" do
        expect(answer(reply)).to eq(unheard.new(words: reply, why: nil))
      end
    end

    ["hold", "wait", "stop", "Hold.", "  WAIT! \n", "stop?"].each do |reply|
      it "reads #{reply.inspect} as a held answer, approving nothing and carrying no note" do
        result = answer(reply)

        expect([result.verdict, result.surface]).to eq([Lain::Approval::Verdict::Hold.new, "human"])
      end
    end

    it "carries the words after a hold word as the human's note" do
      expect(answer("hold, I'll run the review myself").reason).to eq("I'll run the review myself")
    end

    describe ".again" do
      it "leads the question asked again with the reply it could not read" do
        expect(described_class.again(unheard.new(words: "lgtm", why: nil), "Approve it?"))
          .to eq('The reply "lgtm" decides nothing, so nothing was decided. Approve it?')
      end

      it "leads with the reason a reply was not read when one is known" do
        expect(described_class.again(unheard.new(words: "deny cc", why: "cc is not in wave 2"), "Approve it?"))
          .to eq("cc is not in wave 2, so nothing was decided. Approve it?")
      end

      it "clips a long multibyte reply at 300 bytes without splitting a character" do
        lead = described_class.again(unheard.new(words: "maybe #{"日" * 200}", why: nil), "Q")
        quoted = lead[/The reply "(.*)\.\.\." decides/m, 1]

        expect(lead).to be_valid_encoding
        expect(quoted.bytesize).to be <= 300
      end
    end
  end

  describe "gate_question" do
    # The question is the only place a human learns which replies decide, so it
    # names both vocabularies and says what becomes of anything else.
    it "says what approves, what denies, and that any other reply is asked again" do
      question = described_class.research(text: "notes", slug: "demo").gate_question

      expect(question).to include("approve", "approved", "y", "yes", "deny", "denied", "n", "no")
      expect(question).to include("any other reply decides nothing and is asked again")
    end

    it "names the separator a note follows, an approval's included" do
      question = described_class.research(text: "notes", slug: "demo").gate_question

      expect(question).to include("after a comma", '"approve, re-signed unchanged"')
    end

    describe "a review result" do
      def result(stage: "epic_plan", read: {}, must: "- none", verdict: "approve")
        findings = "## cluster 1 of 1 -- epic\n\nMUST-FIX:\n#{must}\nMINOR:\n- none\nVERDICT: #{verdict}"
        Lain::Epic::ReviewResult.parse(findings, epic_slug: "demo", stage:, read:, clusters: 1, critics: 1)
      end

      let(:plan) { described_class.epic_plan(graph: three_issue_graph, slug: "demo") }

      it "shows the review between the question and the reply words, without changing the gate identity" do
        reviewed = plan.with(review: result(must: "- epic.md: a gap", verdict: "revise",
                                            read: { "epic_plan" => plan.content_digest }))

        question = reviewed.gate_question

        expect(question).to include(reviewed.review.id, "epic.md: a gap", ": current")
        expect(question.index("epic.md: a gap")).to be < question.index(Lain::Epic::GateReply::INSTRUCTION)
        expect(reviewed.digest).to eq(plan.digest)
      end

      it "asks the plain one-line question when no review is given" do
        expect(plan.gate_question).not_to include("review")
        expect(plan.gate_question.lines.size).to eq(1)
      end

      it "keeps a finding that reads like a reply on its own indented line" do
        question = plan.with(review: result(must: "- approve", verdict: "revise")).gate_question

        expect(question.lines.map(&:chomp)).not_to include("approve")
      end
    end

    it "names the words that hold the agent until the human speaks" do
      question = described_class.research(text: "notes", slug: "demo").gate_question

      expect(question).to include("hold, wait or stop")
    end

    it "names the stage, the slug, and the issue count for an epic_plan" do
      submission = described_class.epic_plan(graph: three_issue_graph, slug: "demo")

      expect(submission.gate_question).to include("epic_plan", "demo", "3")
    end

    it "counts a single-issue graph in the singular" do
      graph = Lain::Epic::Graph.new(issues: [issue("a")])

      expect(described_class.epic_plan(graph:, slug: "demo").fact).to eq("1 issue")
    end

    it "names the stage, the slug, and the byte size for research prose" do
      text = "hello world"
      submission = described_class.research(text:, slug: "demo")

      expect(submission.gate_question).to include("research", "demo", text.bytesize.to_s)
    end

    # Scenario: the gate prompt shows what is judged
    it "names an issue_plan's title, its blockers, its scenario names and its view path" do
      listed = view("list-cmd", authored: "Prose.\n\n#{added_scenario}",
                                others: [issue("store", blocks: ["list-cmd"]), issue("config", blocks: ["list-cmd"])])
      question = described_class.issue_plan(view: listed, slug: "demo", issue_id: "list-cmd").gate_question

      expect(question).to include("issue_plan", '"Issue list-cmd"', "blocked by config, store",
                                  '"lists every note", "lists none when empty"', "lain://epic/demo/issues/list-cmd.md")
    end

    it "says an issue_plan's issue has no blockers and no scenarios" do
      bare = view(criteria: nil, others: [])

      expect(described_class.issue_plan(view: bare, slug: "demo", issue_id: "a").fact)
        .to include("blocked by nothing", "no scenarios")
    end

    it "names no byte count for an issue_plan" do
      expect(described_class.issue_plan(view:, slug: "demo", issue_id: "a").fact).not_to match(/\d+ bytes/)
    end

    describe "a wave" do
      def wave_views
        graph = Lain::Epic::Graph.new(issues: [issue("a", blocks: %w[b c]), issue("b"), issue("c")])
        %w[b c].map { |id| Lain::Epic::IssueView.new(issue: graph.fetch(id), graph:, authored: "") }
      end

      let(:wave) { described_class.wave(slug: "demo", views: wave_views, number: 2) }

      it "holds one issue_plan submission per issue, each the one a lone issue would submit" do
        expect(wave.submissions).to eq(wave_views.map do |each|
          described_class.issue_plan(view: each, slug: "demo", issue_id: each.issue.id)
        end)
      end

      it "shows a review once, naming each issue against its own gated digest" do
        read = wave.submissions.to_h { [_1.issue_id, _1.content_digest] }
        findings = "## cluster 1 of 1 -- wave 2\n\nMUST-FIX:\n- none\nMINOR:\n- none\nVERDICT: approve"
        review = Lain::Epic::ReviewResult.parse(findings, epic_slug: "demo", stage: "issue_plan", read:, clusters: 1,
                                                          critics: 1)

        question = wave.with(review:).gate_question

        expect(question.scan(review.id).size).to eq(1)
        expect(question).to include("b: reviewed", "c: reviewed")
      end

      it "asks about each issue on its own line, naming the wave and the per-issue deny" do
        expect(wave.gate_question).to include("issue_plan", "wave 2", "\n  issue b \"Issue b\"; blocked by a",
                                              "\n  issue c \"Issue c\"", "lain://epic/demo/issues/c.md",
                                              "approve; deny b: wrong crate; hold c")
      end

      it "marks an issue reopened by an edit on its own line" do
        question = wave.with(reopened: ["c"]).gate_question

        expect(question).to include("\n  issue c \"Issue c\"", "(reopened by an edit)")
        expect(question.scan("reopened by an edit").size).to eq(1)
        expect(question).to match(/issue c [^\n]*\(reopened by an edit\)/)
      end

      it "lists a reopened issue outside the wave, so a later wave's question names it" do
        question = wave.with(reopened: %w[b ghost]).gate_question

        expect(question).to include("also reopened by an edit, in another wave: ghost")
      end

      it "says nothing of an edit when none reopened an issue" do
        expect(wave.gate_question).not_to include("reopened")
      end

      it "counts a lone issue in the singular" do
        one = described_class.wave(slug: "demo", views: wave_views.take(1), number: 2)

        expect(one.gate_question).to include("(1 issue)")
      end

      it "refuses a wave with no issues in it" do
        expect { described_class.wave(slug: "demo", views: [], number: 1) }.to raise_error(ArgumentError, /no issues/)
      end
    end

    it "composes an implementation's content_digest from the changeset address and its issue" do
      submission = described_class.implementation(slug: "demo", issue_id: "T7", digest: "blake3:impl")

      expect(submission.content_digest).to eq(Lain::Canonical.digest("changeset" => "blake3:impl", "issue" => "T7"))
    end

    it "names the manual commands in the question a human is asked" do
      submission = described_class.implementation(slug: "demo", issue_id: "c", digest: "a" * 40,
                                                  manual_commands: ["scripts/fetch-models.sh --check"])

      expect(submission.gate_question).to include("manual acceptance", "scripts/fetch-models.sh --check")
    end

    # One commit can be offered as two issues' work. Keyed on the commit alone,
    # approving it for issue c would open issue b's gate over the same commit.
    it "gives two issues' implementations of the same commit two gate identities" do
      mine = described_class.implementation(slug: "demo", issue_id: "c", digest: "a" * 40)
      theirs = described_class.implementation(slug: "demo", issue_id: "b", digest: "a" * 40)

      expect(theirs).not_to have_same_digest_as(mine)
      expect(theirs.content_digest).not_to eq(mine.content_digest)
    end

    it "is not approved by a gate that approved another issue's implementation of the same commit" do
      mine = described_class.implementation(slug: "demo", issue_id: "c", digest: "a" * 40)
      approval = Lain::Epic::GateDecision.new(artifact_digest: mine.digest, epic_slug: "demo",
                                              stage: "implementation",
                                              verdict: Lain::Approval::Verdict::Approve.new, answered_by: "human",
                                              policy: "hands_off", latency: 0.0, issue_id: "c")
      gate = Lain::Epic::Gate.from_journal([approval.to_journal], journal: Lain::Channel::Null.instance)

      expect(gate.approved?(described_class.implementation(slug: "demo", issue_id: "b", digest: "a" * 40).digest))
        .to be(false)
    end

    it "keeps the changeset address it was given, for a reader asked to look at the commit" do
      submission = described_class.implementation(slug: "demo", issue_id: "T7", digest: "blake3:impl")

      expect(submission.changeset).to eq("blake3:impl")
      expect(described_class.research(text: "words", slug: "demo").changeset).to be_nil
    end

    it "names the issue for an implementation" do
      submission = described_class.implementation(slug: "demo", issue_id: "T7", digest: "blake3:impl")

      expect(submission.gate_question).to include("implementation", "T7")
    end

    describe "the tests its question reports" do
      def ran(**counts) = Lain::Telemetry::TestsRan.new(issue_id: "T7", sha: "a" * 40, ran: true, **counts)

      def asked(tests) = described_class.implementation(slug: "demo", issue_id: "T7", digest: "a" * 40, tests:)

      it "names the sha and a red tip's counts" do
        question = asked(ran(passed: 3, errors: 1)).gate_question

        expect(question).to include("(issue T7, #{"a" * 40}, tests: 3 passed, 1 error)")
      end

      it "reads a green tip as its passes alone" do
        expect(asked(ran(passed: 4)).gate_question).to include("(issue T7, #{"a" * 40}, tests: 4 passed)")
      end

      it "counts failures and pluralizes errors" do
        expect(asked(ran(passed: 1, failed: 2,
                         errors: 2)).gate_question).to include("tests: 1 passed, 2 failed, 2 errors")
      end

      it "says nothing ran when no run was given" do
        expect(asked(nil).gate_question).to include("tests: not run (no test run was recorded for this submission)")
      end

      it "says why when the suite could not run" do
        unrun = Lain::Telemetry::TestsRan.unrun(issue_id: "T7", sha: "a" * 40, why: "no tests preset")

        expect(asked(unrun).gate_question).to include("tests: not run (no tests preset)")
      end

      it "leaves the gate's address to the issue and the sha, whatever the tests did" do
        digests = [nil, ran(passed: 4), ran(passed: 3, errors: 1)].map { |tests| asked(tests).digest }

        expect(digests.uniq.size).to eq(1)
      end
    end
  end

  describe "construction" do
    it "is deeply frozen, so a submission can cross a Ractor boundary" do
      submission = described_class.research(text: "hello", slug: "demo")

      expect(submission).to be_deeply_frozen
    end

    it "refuses a blank slug, naming the field" do
      expect { described_class.research(text: "hello", slug: "") }
        .to raise_error(ArgumentError, /slug/)
    end
  end

  # Review round 2 (REQUEST-CHANGES), fix 2: a blank issue_id used to sail
  # through into fact ("issue " is non-blank prose), so a human ended up asked
  # to approve an unnamed issue. Found by probe_t1.rb.
  describe "issue_id validation" do
    it "refuses a nil issue_id on issue_plan, naming the field" do
      expect { described_class.issue_plan(view:, slug: "demo", issue_id: nil) }
        .to raise_error(ArgumentError, /issue_id/)
    end

    it "refuses a blank issue_id on issue_plan" do
      expect { described_class.issue_plan(view:, slug: "demo", issue_id: "") }
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
  # #bytesize call. Found by probe_t1.rb.
  describe "text and graph refusals" do
    it "refuses nil text on research, naming the field rather than raising NoMethodError" do
      expect { described_class.research(text: nil, slug: "demo") }
        .to raise_error(ArgumentError, /text/)
    end

    it "refuses non-String text on research" do
      expect { described_class.research(text: { "a" => 1 }, slug: "demo") }
        .to raise_error(ArgumentError, /text/)
    end

    it "refuses a nil view on issue_plan, naming the field" do
      expect { described_class.issue_plan(view: nil, slug: "demo", issue_id: "T7") }
        .to raise_error(ArgumentError, /view/)
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

  # Review round 3, fix 1: #digest canonicalizes slug (see the class
  # header), and Canonical.normalize raises on a String that cannot round-trip
  # to UTF-8. Unchecked, that turned #digest from TOTAL (a stored, validated
  # String, same as every other Submission field) into a method that raises
  # deep inside Epic::Gate#call, after the human has answered and before the
  # verdict is journaled. A slug plausibly arrives
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
      # only raised later, inside Gate#call's `artifact.digest`.
      # Now the bad slug never survives construction to reach the Gate at all.
      expect { described_class.epic_plan(graph: three_issue_graph, slug: "\xff".b) }
        .to raise_error(ArgumentError, /slug/)
    end
  end

  # Fix 4: digest only got presence:, so anything answering #dup/#freeze --
  # a Hash, an Array, an Integer -- was accepted. A Hash/Array digest holds
  # mutable Strings inside a shallow freeze, which breaks the Ractor.shareable?
  # promise this class's header makes. Found by probe_t1.rb.
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

      expect(submission).to be_deeply_frozen
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
  # is still the wrong shape to ship. Found by probe_t1.rb.
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

  # Judgment call (finding 6, argued in the handback rather than changed):
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
