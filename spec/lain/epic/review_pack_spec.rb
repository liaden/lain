# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Epic::ReviewPack do
  def issue(id, blocks: []) = Lain::Epic::Issue.new(id:, title: "the #{id} issue", blocks:)

  # 6 waves: a1, b1, c1 c2, d1, e1, f1.
  def graph
    Lain::Epic::Graph.new(issues: [issue("a1", blocks: ["b1"]), issue("b1", blocks: %w[c1 c2]),
                                   issue("c1", blocks: ["d1"]), issue("c2", blocks: ["d1"]),
                                   issue("d1", blocks: ["e1"]), issue("e1", blocks: ["f1"]), issue("f1")])
  end

  def write_issue(id, body = "BODY-#{id}\n") = File.write(@home.issue(id).path, body)

  def pack(stage: "issue_plan", wave: 3) = described_class.for(@home.read_epic, @home, records, stage:, wave:)

  def gated(id)
    view = Lain::Epic::IssueView.read(@home, id)
    Lain::Epic::Submission.issue_plan(view:, slug: "nyotes", issue_id: id).content_digest
  end

  def reviewed(read, must_fix: "issues/c1.md: no owner is named", slug: "nyotes", stage: "issue_plan",
               documents: {})
    findings = "## cluster 1 of 1 -- wave 3\n\nMUST-FIX:\n- #{must_fix}\nMINOR:\n- none\nVERDICT: revise\n"
    Lain::Epic::ReviewResult.parse(findings, epic_slug: slug, stage:, read:, documents:, clusters: 1, critics: 1)
                            .to_journal
  end

  def bytes(relative) = Lain::Workspace::Snapshot::Blob.new(bytes: File.binread(File.join(@home.path, relative))).digest

  def read_now = %w[epic.md research.md issues/c1.md issues/c2.md].to_h { [_1, bytes(_1)] }

  def answered(question, answer, epic_slug: "nyotes")
    Lain::Telemetry::QuestionAnswered.new(question:, answer:, requester: "chat", epic_slug:).to_journal
  end

  let(:records) { [] }

  around do |example|
    Dir.mktmpdir("lain-review-pack") do |made|
      @project = File.realpath(made)
      example.run
    end
  end

  before do
    paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@project, "state"), "HOME" => @project })
    @home = Lain::Epic::Home.resolve(config: Lain::Config.new(epics: Lain::Config::Epics.new(home: :repo)), paths:,
                                     root: @project, slug: "nyotes")
    FileUtils.mkdir_p(File.join(@home.path, "issues"))
    @home.write_epic(graph)
    %w[a1 b1 c1 c2].each { write_issue(_1) }
  end

  describe "the reviewer knows the layout" do
    it "lists every wave's ids and marks which are written" do
      expect(pack.layout.map { [_1.number, _1.ids, _1.written] })
        .to eq([[1, ["a1"], ["a1"]], [2, ["b1"], ["b1"]], [3, %w[c1 c2], %w[c1 c2]], [4, ["d1"], []],
                [5, ["e1"], []], [6, ["f1"], []]])
    end

    it "scopes the verdict to the reviewed wave's ids" do
      expect(pack.scope_ids).to eq(%w[c1 c2])
      expect(pack.to_s).to include("wave 3 of 6", "covers c1, c2 only")
    end

    it "tells the reviewer to judge a later wave's unwritten issue against epic.md" do
      text = pack.to_s

      expect(text).to include("wave 5: e1 (not written)", "wave 3: c1 (written), c2 (written)")
      expect(text).to match(/not written.*judge.*against epic\.md.*not.*missing/m)
    end

    it "scopes an epic_plan review to epic.md" do
      expect(pack(stage: "epic_plan", wave: nil).scope_ids).to eq(["epic_plan"])
    end
  end

  describe "answered questions are evidence" do
    let(:records) do
      [reviewed({}), answered("Who blesses the owner?", "the human does, in round 6"),
       answered("Unrelated?", "another epic", epic_slug: "other"), answered("Stray?", "no epic", epic_slug: nil)]
    end

    it "carries every answer the human gave about this epic, and no other" do
      expect(pack.answers.map { [_1.question, _1.answer] }).to eq([["Who blesses the owner?",
                                                                    "the human does, in round 6"]])
    end

    it "shows them to the reviewer in a later round" do
      expect(pack.to_s).to include("Who blesses the owner?", "the human does, in round 6")
      expect(pack.to_s).not_to include("another epic")
    end
  end

  describe "a second round reads the diff" do
    let(:records) { [] }

    before do
      records << reviewed(%w[c1 c2].to_h { [_1, gated(_1)] })
      write_issue("c1", "BODY-c1 revised\n")
    end

    it "carries the earlier round as prior" do
      expect(pack.prior.map(&:must_fix)).to eq([["issues/c1.md: no owner is named"]])
      expect(pack.to_s).to include("issues/c1.md: no owner is named")
    end

    it "counts each reviewed id's earlier rounds" do
      records << reviewed({ "c2" => gated("c2") })

      expect(pack.rounds).to eq("c1" => 1, "c2" => 2)
      expect(pack.spent(2)).to eq(["c2"])
    end

    it "counts no round whose closing blocks did not parse" do
      2.times do
        records << Lain::Epic::ReviewResult.parse("a refused reviewer\n", epic_slug: "nyotes", stage: "issue_plan",
                                                                          read: { "c2" => gated("c2") }, clusters: 1,
                                                                          critics: 1).to_journal
      end

      expect(pack.rounds).to eq("c1" => 1, "c2" => 1)
    end

    it "counts every attempt, parsed or not, toward an outer ceiling" do
      3.times do
        records << Lain::Epic::ReviewResult.parse("a refused reviewer\n", epic_slug: "nyotes", stage: "issue_plan",
                                                                          read: { "c2" => gated("c2") }, clusters: 1,
                                                                          critics: 1).to_journal
      end

      expect(pack.attempts).to eq("c1" => 1, "c2" => 4)
      expect(pack.exhausted(4)).to eq(["c2"])
    end

    it "counts a round over every wave toward each wave's ids" do
      records << reviewed(%w[a1 b1 c1 c2].to_h { [_1, gated(_1)] })

      expect(pack.spent(2)).to eq(%w[c1 c2])
    end

    it "counts only rounds over the same slug, stage and wave" do
      records << reviewed({ "a1" => gated("a1") }) << reviewed({ "c1" => "x", "c2" => "y" }, slug: "other")
      records << reviewed({ "epic_plan" => "z" }, stage: "epic_plan")

      expect(pack.prior.size).to eq(1)
      expect(pack(wave: 1).prior.size).to eq(1)
      expect(pack(stage: "epic_plan", wave: nil).prior.size).to eq(1)
    end

    it "takes the findings and the digests from the latest round" do
      shown = { "issues/c1.md" => bytes("issues/c1.md") }
      records << reviewed({ "c1" => gated("c1"), "c2" => "older" }, must_fix: "issues/c2.md: later finding",
                                                                    documents: shown)

      expect(pack.prior.last.must_fix).to eq(["issues/c2.md: later finding"])
      expect(pack.diff.shown).to eq(shown)
    end
  end

  describe "documents the previous round read" do
    before do
      File.write(File.join(@home.path, "research.md"), "RESEARCH\n")
      records << reviewed(%w[c1 c2].to_h { [_1, gated(_1)] }, documents: read_now)
      write_issue("c1", "BODY-c1 revised\n")
    end

    it "carries the digests the latest round showed its reviewers" do
      expect(pack.diff.shown).to eq(read_now.merge("issues/c1.md" => records.first.dig("documents", "issues/c1.md")))
      expect(pack.to_s).to include("shown below by its digest alone")
    end

    it "knows nothing from a record written before documents were recorded" do
      records.replace([reviewed(%w[c1 c2].to_h { [_1, gated(_1)] }).except("documents")])

      expect(pack.diff.shown).to eq({})
    end

    it "knows nothing from a round whose closing blocks did not parse" do
      unparsed = Lain::Epic::ReviewResult.parse("a refused reviewer\n", epic_slug: "nyotes", stage: "issue_plan",
                                                                        read: %w[c1 c2].to_h { [_1, gated(_1)] },
                                                                        documents: read_now, clusters: 1, critics: 1)
      records << unparsed.to_journal

      expect(pack.diff.shown).to eq({})
      expect(pack.to_s).to include("shown in full")
    end

    it "names a document the round read that is gone since" do
      FileUtils.rm(File.join(@home.path, "research.md"))

      expect(pack.diff.deleted).to eq(["research.md"])
      expect(pack.to_s).to include("Deleted since the previous round: research.md")
    end
  end

  describe "a first round" do
    it "has no prior and knows no document" do
      expect(pack.prior).to be_empty
      expect(pack.diff).to have_attributes(shown: {}, deleted: [])
    end

    it "reads each reviewed issue's gated digest now" do
      expect(pack.diff.now).to eq(%w[c1 c2].to_h { [_1, gated(_1)] })
    end
  end
end
