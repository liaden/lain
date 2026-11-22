# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# The review the tool's critique runs: a spawn that records each child's prompt.
class EpicReviewSpecSpawn
  Seam = Struct.new(:context_factory, :provider)

  attr_reader :prompts

  # @param reply [#call, nil] `(child number, model) -> String`, each child's findings
  def initialize(reply: nil)
    @prompts = []
    @reply = reply || ->(child, model) { "VERDICT for child #{child} (#{model.class})" }
  end

  def seam = Seam.new(-> { Lain::Context.new(model: "critic-model", max_tokens: 512) }, Lain::Provider::Mock.new)

  def within(_worker_env) = Lent.new(@prompts, @reply)

  def never_parking = self

  # One lent spawn.
  class Lent
    def initialize(prompts, reply)
      @prompts = prompts
      @reply = reply
    end

    def call(_role, _mode, prompt, model: nil)
      @prompts << prompt
      reply = @reply.call(@prompts.size, model)
      reply.is_a?(Lain::Tool::Result) ? reply : Lain::Tool::Result.ok(reply)
    end
  end
end

RSpec.describe Lain::Tools::EpicReview, :seam do
  def issue(id, blocks: []) = Lain::Epic::Issue.new(id:, title: "the #{id} issue", blocks:)

  def graph
    Lain::Epic::Graph.new(issues: [issue("a1", blocks: %w[b2 b3]), issue("b2", blocks: ["c4"]), issue("b3"),
                                   issue("c4")])
  end

  def invoke(**args)
    described_class.new(homes:, critique:, critics:).call(args.transform_keys(&:to_s),
                                                          Lain::Tool::Invocation.new(context: Lain::Session::Null.instance))
  end

  def critique = real_critique

  def found(text) = Lain::Review::Critique::Findings.new(text, [])

  def real_critique
    lambda do |subject:, instructions:|
      Lain::Review::Critique.new(subject:, spawn:, window:, journal: [], slots: @slots, instructions:, critics:,
                                 checkouts: Lain::Review::Critique::Documents::ReadRoots.new(root: subject.root,
                                                                                             worker_env:)).call
    end
  end

  def window
    Lain::CLI::Backend::WindowBook::Served.new(model: "critic-model", window_tokens: 32_768,
                                               provenance: Lain::ContextWindow::PROBED)
  end

  let(:spawn) { EpicReviewSpecSpawn.new }
  let(:critics) { 1 }
  let(:worker_env) { Lain::WorkerEnv.new(cwd: Dir.pwd, env: { "LANG" => "C" }) }
  let(:homes) { instance_double(Lain::CLI::EpicMount::Homes) }
  let(:journal) { [] }
  let(:answers) { [] }

  around do |example|
    Dir.mktmpdir("lain-epic-review") do |made|
      @project = File.realpath(made)
      @home_path = File.join(@project, "nyotes")
      @slots = Lain::Prompt::Slots.load(root: made)
      example.run
    end
  end

  before do
    paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@home_path, "state"), "HOME" => @home_path })
    @paths = paths
    @config = Lain::Config.new(epics: Lain::Config::Epics.new(home: :repo))
    home = Lain::Epic::Home.resolve(config: @config, paths:, root: @project, slug: "nyotes")
    @home_path = home.path
    FileUtils.mkdir_p(File.join(@home_path, "issues"))
    home.write_epic(graph)
    File.write(File.join(@home_path, "research.md"), "RESEARCH-CONTEXT\n")
    %w[a1 b2 b3 c4].each { File.write(File.join(@home_path, "issues", "#{_1}.md"), "BODY-#{_1}\n") }
    allow(homes).to receive(:for).with("nyotes").and_return(home)
    allow(homes).to receive(:journal).and_return(journal)
    allow(homes).to receive(:review_results) { journal.map(&:to_journal) + answers }
    @home = home
  end

  def shown(prompt) = %w[a1 b2 b3 c4].select { prompt.include?("BODY-#{_1}\n") }

  describe "stage issue_plan" do
    it "spawns one fresh reviewer per wave, each reading only its wave and the shared files" do
      result = invoke(stage: "issue_plan", slug: "nyotes")

      expect(result).not_to be_error
      expect(spawn.prompts.map { shown(_1) }).to eq([%w[a1], %w[b2 b3], %w[c4]])
      expect(spawn.prompts).to all(include("RESEARCH-CONTEXT"))
    end

    it "shows every wave's reviewer epic.md as shared context" do
      invoke(stage: "issue_plan", slug: "nyotes")

      expect(spawn.prompts).to all(include("## epic.md"))
      expect(spawn.prompts).to all(include("the b2 issue"))
    end

    it "returns the merged findings" do
      text = invoke(stage: "issue_plan", slug: "nyotes").text

      expect(text).to include("VERDICT for child 1", "VERDICT for child 3")
    end

    it "reviews one wave when a wave number is named" do
      invoke(stage: "issue_plan", slug: "nyotes", wave: 2)

      expect(spawn.prompts.map { shown(_1) }).to eq([%w[b2 b3]])
    end

    it "refuses a wave the graph does not have" do
      result = invoke(stage: "issue_plan", slug: "nyotes", wave: 9)

      expect(result).to be_error
      expect(result.text).to include("wave 9", "3 waves")
      expect(spawn.prompts).to be_empty
    end

    it "answers a missing issue file as an error rather than raising" do
      FileUtils.rm(File.join(@home_path, "issues", "b3.md"))

      result = invoke(stage: "issue_plan", slug: "nyotes")

      expect(result).to be_error
      expect(result.text).to include("issues/b3.md")
    end
  end

  describe "stage epic_plan" do
    it "reviews epic.md in one child with the research as shared context" do
      invoke(stage: "epic_plan", slug: "nyotes")

      expect(spawn.prompts.size).to eq(1)
      expect(spawn.prompts.first).to include("RESEARCH-CONTEXT", "the b2 issue")
    end

    it "refuses a wave, which only an issue_plan has" do
      expect { invoke(stage: "epic_plan", slug: "nyotes", wave: 1) }.to raise_error(Lain::Tool::InvalidInput, /wave/i)
    end
  end

  it "refuses an unknown stage by validation" do
    expect { invoke(stage: "research", slug: "nyotes") }.to raise_error(Lain::Tool::InvalidInput, /stage/i)
  end

  describe "findings longer than the output bound" do
    let(:long) { Array.new(40) { |index| "finding #{index}: #{"x" * 1024}" }.join("\n\n") }
    let(:reply) { long }

    def critique = ->(**) { found(reply) }

    it "keeps whole paragraphs from the front and says what it withheld" do
      text = invoke(stage: "issue_plan", slug: "nyotes").text

      expect(text.bytesize).to be <= described_class::BOUND.limit
      expect(text).to start_with("finding 0:").and include("truncated", "withholding")
      expect(text).not_to include("finding 39")
    end

    it "suggests one wave at a time only for an issue_plan that named none" do
      advice = ->(**args) { invoke(stage: "issue_plan", slug: "nyotes", **args).text.include?("`wave`") }

      expect(advice.call).to be(true)
      expect(advice.call(wave: 2)).to be(false)
      expect(invoke(stage: "epic_plan", slug: "nyotes").text).not_to include("`wave`")
    end

    context "when the first paragraph alone is over the ceiling" do
      let(:reply) { "é" * 200_000 }

      it "cuts it on a character boundary under the ceiling" do
        text = invoke(stage: "issue_plan", slug: "nyotes").text

        expect(text.bytesize).to be <= described_class::BOUND.limit
        expect(text).to be_valid_encoding.and start_with("éé").and include("truncated")
      end
    end

    context "when several waves overflow" do
      let(:reply) do
        (1..3).map { |wave| "## wave #{wave}\n\n#{"y" * 9000}\n\nVERDICT: revise #{wave}" }.join("\n\n")
      end

      it "keeps every cluster's verdict line past the cut" do
        text = invoke(stage: "issue_plan", slug: "nyotes").text

        expect(text.bytesize).to be <= described_class::BOUND.limit
        expect(text).to include("VERDICT: revise 1", "VERDICT: revise 2", "VERDICT: revise 3")
      end
    end
  end

  describe "refusals" do
    def critique = ->(**) {}

    it "says plainly that a missing epic does not exist, without a path" do
      paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@project, "state"), "HOME" => @project })
      ghost = Lain::Epic::Home.resolve(config: Lain::Config.new(epics: Lain::Config::Epics.new(home: :repo)), paths:,
                                       root: @project, slug: "ghost")
      allow(homes).to receive(:for).with("ghost").and_return(ghost)

      %w[epic_plan issue_plan].each do |stage|
        result = invoke(stage:, slug: "ghost")

        expect(result).to be_error
        expect(result.text).to eq("there is no epic named `ghost`; create it with epic_write first")
      end
    end

    it "fails loudly when the critique returns nothing" do
      result = invoke(stage: "issue_plan", slug: "nyotes")

      expect(result).to be_error
      expect(result.text).to include("returned no findings")
    end
  end

  it "names itself epic_review" do
    expect(described_class.new(homes:, critique:).name).to eq("epic_review")
  end

  describe "the review it journals" do
    let(:findings) do
      "## cluster 1 of 1 -- epic\nfiles: epic.md\n\nProse.\n\n" \
        "MUST-FIX:\n- epic.md: a gap\nMINOR:\n- none\nVERDICT: revise\n"
    end

    def critique = ->(**) { found(findings) }

    def gated_plan(id)
      Lain::Epic::Submission.issue_plan(view: Lain::Epic::IssueView.read(@home, id), slug: "nyotes", issue_id: id)
    end

    it "binds an epic_plan review to the digest its gate would sign" do
      invoke(stage: "epic_plan", slug: "nyotes")

      expect(journal.map(&:read)).to eq([{ "epic_plan" => Lain::Epic::Submission.epic_plan(graph: @home.read_epic,
                                                                                           slug: "nyotes")
                                                                                .content_digest }])
    end

    it "binds an issue_plan review to each reviewed issue's gated digest" do
      invoke(stage: "issue_plan", slug: "nyotes", wave: 2)

      expect(journal.first.read).to eq(%w[b2 b3].to_h { [_1, gated_plan(_1).content_digest] })
    end

    it "reads the closing block, and ends its result with the id epic_submit takes" do
      text = invoke(stage: "epic_plan", slug: "nyotes").text

      expect(journal.first).to have_attributes(epic_slug: "nyotes", stage: "epic_plan", verdict: "revise",
                                               must_fix: ["epic.md: a gap"])
      expect(text).to include("MUST-FIX:")
      expect(text.lines.last).to include(journal.first.id, "`review`")
    end

    describe "over the real critique's merged findings" do
      let(:spawn) do
        EpicReviewSpecSpawn.new(reply: lambda { |child, _model|
          "MUST-FIX:\n- none\nMINOR:\n- note #{child}\nVERDICT: approve"
        })
      end

      def critique = real_critique

      # The parser splits on the cluster and critic headings the real critique writes.
      it "reads one closing block from each wave's reviewer" do
        invoke(stage: "issue_plan", slug: "nyotes")

        expect(journal.first).to have_attributes(verdict: "approve", minor: ["note 1", "note 2", "note 3"])
      end

      # Neither side names a count, so both run on Critique's one default.
      it "reads a critique built with its default critics, through the tool's own default" do
        defaulted = lambda do |subject:, instructions:|
          Lain::Review::Critique.new(subject:, spawn:, window:, journal: [], slots: @slots, instructions:,
                                     checkouts: Lain::Review::Critique::Documents::ReadRoots.new(
                                       root: subject.root, worker_env:
                                     )).call
        end

        described_class.new(homes:, critique: defaulted)
                       .call({ "stage" => "issue_plan", "slug" => "nyotes" },
                             Lain::Tool::Invocation.new(context: Lain::Session::Null.instance))

        expect(journal.first.verdict).to eq("approve")
        expect(spawn.prompts.size).to eq(3 * Lain::Review::Critique::DEFAULT_CRITICS)
      end

      context "when 2 critics read each wave" do
        let(:critics) { 2 }

        it "reads one closing block from each critic" do
          invoke(stage: "issue_plan", slug: "nyotes", wave: 2)

          expect(journal.first).to have_attributes(verdict: "approve", minor: ["note 1", "note 2"])
        end

        it "reads nothing when the tool was told 1 critic ran" do
          described_class.new(homes:, critique:, critics: 1)
                         .call({ "stage" => "issue_plan", "slug" => "nyotes", "wave" => 2 },
                               Lain::Tool::Invocation.new(context: Lain::Session::Null.instance))

          expect(journal.first.verdict).to eq("unparsed")
        end
      end
    end

    it "journals nothing when the critique refused" do
      invoke(stage: "issue_plan", slug: "nyotes", wave: 9)

      expect(journal).to be_empty
    end
  end

  describe "the context pack" do
    let(:spawn) do
      EpicReviewSpecSpawn.new(reply: lambda { |child, _model|
        "MUST-FIX:\n- issues/b2.md: round #{child} wants an owner\nMINOR:\n- none\nVERDICT: revise"
      })
    end

    def bytes(relative)
      Lain::Workspace::Snapshot::Blob.new(bytes: File.binread(File.join(@home_path, relative))).digest
    end

    def abbreviated(relative) = Lain::Canonical.abbreviate(bytes(relative), scheme: false)

    it "tells the reviewer every wave, which are written, and that its verdict covers its wave only" do
      FileUtils.rm(File.join(@home_path, "issues", "c4.md"))

      result = invoke(stage: "issue_plan", slug: "nyotes", wave: 2)

      expect(result).not_to be_error
      expect(spawn.prompts.first).to include("wave 2 of 3", "covers b2, b3 only", "wave 3: c4 (not written)",
                                             "against epic.md")
    end

    it "carries the human's answers about this epic" do
      answers << Lain::Telemetry::QuestionAnswered.new(question: "Who blesses the owner?", answer: "OWNER-BLESSED",
                                                       epic_slug: "nyotes").to_journal

      invoke(stage: "issue_plan", slug: "nyotes", wave: 2)

      expect(spawn.prompts.first).to include("Who blesses the owner?", "OWNER-BLESSED")
    end

    it "shows round 2 round 1's findings, the changed issue whole and the unchanged one by digest" do
      invoke(stage: "issue_plan", slug: "nyotes", wave: 2)
      File.write(File.join(@home_path, "issues", "b2.md"), "BODY-b2 revised\n")

      invoke(stage: "issue_plan", slug: "nyotes", wave: 2)

      second = spawn.prompts.last
      expect(second).to include("issues/b2.md: round 1 wants an owner", "BODY-b2 revised",
                                abbreviated("issues/b3.md"))
      expect(second).not_to include("BODY-b3\n")
    end

    it "shows round 2 the unchanged research.md and epic.md by digest only" do
      invoke(stage: "issue_plan", slug: "nyotes", wave: 2)
      invoke(stage: "issue_plan", slug: "nyotes", wave: 2)

      second = spawn.prompts.last
      expect(second).to include("## research.md", abbreviated("research.md"), abbreviated("epic.md"))
      expect(second).not_to include("RESEARCH-CONTEXT", "the b2 issue")
    end

    it "journals the digest of every document the round read" do
      invoke(stage: "issue_plan", slug: "nyotes", wave: 2)

      expect(journal.first.documents).to eq(%w[epic.md research.md issues/b2.md issues/b3.md].to_h { [_1, bytes(_1)] })
    end

    describe "through the real homes" do
      let(:homes) do
        Lain::CLI::EpicMount::Homes.new(journal:, root: @project, paths: @paths, config: @config)
      end

      # The outer setup stubs these for every other example; here the homes answer for themselves.
      before { %i[for review_results].each { allow(homes).to receive(_1).and_call_original } }

      it "reads the human's answers out of the session journals" do
        dir = @paths.filing_dir(root: @project)
        FileUtils.mkdir_p(dir)
        answer = Lain::Telemetry::QuestionAnswered.new(question: "Who blesses the owner?", answer: "OWNER-BLESSED",
                                                       epic_slug: "nyotes")
        File.write(File.join(dir, "earlier.ndjson"),
                   "#{JSON.generate({ "ts" => Time.now.utc.iso8601(6), **answer.to_journal })}\n")

        result = invoke(stage: "issue_plan", slug: "nyotes", wave: 2)

        expect(result).not_to be_error
        expect(spawn.prompts.first).to include("OWNER-BLESSED")
      end
    end

    it "refuses a third round on a wave, telling the agent to submit and quote the open findings" do
      2.times { invoke(stage: "issue_plan", slug: "nyotes", wave: 2) }

      result = invoke(stage: "issue_plan", slug: "nyotes", wave: 2)

      expect(result).to be_error
      expect(result.text).to include("2 rounds", "epic_submit", journal.last.id, "issues/b2.md: round 2 wants an owner")
      expect([spawn.prompts.size, journal.size]).to eq([2, 2])
      expect(invoke(stage: "issue_plan", slug: "nyotes", wave: 1)).not_to be_error
    end

    it "refuses a review of every wave once a wave in it has had 2 rounds, naming the spent ids" do
      2.times { invoke(stage: "issue_plan", slug: "nyotes", wave: 2) }

      result = invoke(stage: "issue_plan", slug: "nyotes")

      expect(result).to be_error
      expect(result.text).to include("b2, b3", "epic_submit")
      expect(spawn.prompts.size).to eq(2)
    end

    it "keeps the cap on a wave an issue was added to" do
      2.times { invoke(stage: "issue_plan", slug: "nyotes", wave: 2) }
      @home.write_epic(Lain::Epic::Graph.new(issues: [issue("a1", blocks: %w[b2 b3 b9]), issue("b2", blocks: ["c4"]),
                                                      issue("b3"), issue("c4"), issue("b9")]))
      File.write(File.join(@home_path, "issues", "b9.md"), "BODY-b9\n")

      result = invoke(stage: "issue_plan", slug: "nyotes", wave: 2)

      expect(result).to be_error
      expect(result.text).to include("b2, b3", "never reviewed: b9")
    end

    context "when round 1's reviewer was refused" do
      let(:spawn) do
        EpicReviewSpecSpawn.new(reply: lambda { |child, _model|
          refused = Lain::Tool::Result.error("provider refused: rate limited")
          child == 1 ? refused : "MUST-FIX:\n- none\nMINOR:\n- none\nVERDICT: approve"
        })
      end

      it "shows round 2 every document in full" do
        invoke(stage: "issue_plan", slug: "nyotes", wave: 2)
        invoke(stage: "issue_plan", slug: "nyotes", wave: 2)

        expect(journal.first.verdict).to eq("unparsed")
        expect(spawn.prompts.last).to include("BODY-b2\n", "BODY-b3\n", "RESEARCH-CONTEXT")
      end
    end

    context "when every reviewer fails to return a verdict" do
      let(:spawn) { EpicReviewSpecSpawn.new(reply: ->(*) { "I read it. No closing block." }) }

      it "runs 4 rounds and refuses the 5th, naming the ids and telling the agent to submit" do
        results = Array.new(5) { invoke(stage: "issue_plan", slug: "nyotes", wave: 2) }

        expect(results.map(&:error?)).to eq(([false] * 4) + [true])
        expect(results.last.text).to include("failed to return a verdict", "b2, b3", "epic_submit")
        expect(spawn.prompts.size).to eq(4)
      end
    end

    def human_verdict(issue_id)
      Lain::Epic::GateDecision.new(artifact_digest: "blake3:#{"a" * 64}", epic_slug: "nyotes", stage: "issue_plan",
                                   verdict: Lain::Approval::Verdict::Deny.new(note: "fix b2"), answered_by: "human",
                                   policy: "interactive", latency: 1.0, issue_id:).to_journal
    end

    context "when every reviewer's turn raises" do
      let(:spawn) { EpicReviewSpecSpawn.new(reply: ->(*) { raise IOError, "connection reset" }) }

      it "records each critic's outcome as failed" do
        invoke(stage: "issue_plan", slug: "nyotes", wave: 2)

        expect(journal.last.outcomes).to eq(["failed"])
      end

      it "refuses the third call after 2 failed rounds, naming the provider failure" do
        results = Array.new(3) { invoke(stage: "issue_plan", slug: "nyotes", wave: 2) }

        expect(results.map(&:error?)).to eq([false, false, true])
        expect(results.last.text).to include("provider", "2 rounds", "b2, b3", "epic_submit", "human verdict")
        expect(spawn.prompts.size).to eq(2)
      end

      it "runs again once a human has given a verdict on the ids" do
        2.times { invoke(stage: "issue_plan", slug: "nyotes", wave: 2) }
        answers << human_verdict("b2") << human_verdict("b3")

        expect(invoke(stage: "issue_plan", slug: "nyotes", wave: 2)).not_to be_error
        expect(spawn.prompts.size).to eq(3)
      end
    end

    context "when a human's note follows 2 reviewed rounds" do
      let(:spawn) { EpicReviewSpecSpawn.new(reply: ->(*) { "MUST-FIX:\n- none\nMINOR:\n- none\nVERDICT: approve" }) }

      it "refuses before the verdict and reviews after it" do
        2.times { invoke(stage: "issue_plan", slug: "nyotes", wave: 2) }

        expect(invoke(stage: "issue_plan", slug: "nyotes", wave: 2)).to be_error

        answers << human_verdict("b2") << human_verdict("b3")

        expect(invoke(stage: "issue_plan", slug: "nyotes", wave: 2)).not_to be_error
      end
    end

    context "when an injected critique returns a plain String" do
      def critique = ->(**) { "no block here" }

      it "counts as no failed round" do
        3.times { invoke(stage: "issue_plan", slug: "nyotes", wave: 2) }

        expect(journal.map(&:outcomes)).to eq([[]] * 3)
      end
    end

    context "when the reviewers are refused rather than failed" do
      let(:spawn) { EpicReviewSpecSpawn.new(reply: ->(*) { Lain::Tool::Result.error("provider refused") }) }

      it "counts no failed round, so only the outer attempt ceiling stops it" do
        results = Array.new(5) { invoke(stage: "issue_plan", slug: "nyotes", wave: 2) }

        expect(journal.map(&:outcomes).uniq).to eq([["refused"]])
        expect(results.map(&:error?)).to eq(([false] * 4) + [true])
      end
    end

    context "when only round 1 returns a verdict" do
      let(:spawn) do
        EpicReviewSpecSpawn.new(reply: lambda { |child, _model|
          child == 1 ? "MUST-FIX:\n- issues/b2.md: needs an owner\nMINOR:\n- none\nVERDICT: revise" : "no block"
        })
      end

      it "refuses the 5th call with round 1's review id and must-fix, saying only the later rounds failed" do
        results = Array.new(5) { invoke(stage: "issue_plan", slug: "nyotes", wave: 2) }

        expect(results.map(&:error?)).to eq(([false] * 4) + [true])
        expect(results.last.text).to include("the 3 rounds after review #{journal.first.id}", "epic_submit",
                                             "review #{journal.first.id}", "- issues/b2.md: needs an owner")
      end
    end

    context "when the provider refuses rounds 1 and 2" do
      let(:spawn) do
        EpicReviewSpecSpawn.new(reply: lambda { |child, _model|
          refused = Lain::Tool::Result.error("provider down")
          child <= 2 ? refused : "MUST-FIX:\n- none\nMINOR:\n- none\nVERDICT: approve"
        })
      end

      it "spends no round on them, so a third call runs" do
        3.times { invoke(stage: "issue_plan", slug: "nyotes", wave: 2) }

        expect(journal.map(&:verdict)).to eq(%w[unparsed unparsed approve])
      end
    end

    it "records the digest of the bytes the reviewer was shown, not of an earlier read" do
      target = File.join(@home_path, "issues", "b2.md")
      allow(Lain::Epic::ReviewPack).to receive(:for).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap { File.write(target, "BODY-b2 EDITED-MID\n") if journal.empty? }
      end
      invoke(stage: "issue_plan", slug: "nyotes", wave: 2)
      File.write(target, "BODY-b2\n")

      invoke(stage: "issue_plan", slug: "nyotes", wave: 2)

      expect(spawn.prompts.first).to include("EDITED-MID")
      expect(spawn.prompts.last).to include("BODY-b2\n")
    end

    it "tells round 2 a shared document was deleted since round 1" do
      invoke(stage: "issue_plan", slug: "nyotes", wave: 2)
      FileUtils.rm(File.join(@home_path, "research.md"))

      invoke(stage: "issue_plan", slug: "nyotes", wave: 2)

      expect(spawn.prompts.last).to include("Deleted since the previous round: research.md")
    end
  end

  # The prompt asks for the block the parser reads, so the two cannot drift.
  it "asks reviewers for a closing block its own example of which parses" do
    example = described_class::INSTRUCTIONS[/^MUST-FIX:\n.*?^VERDICT: \w+$/m]
    result = Lain::Epic::ReviewResult.parse("## cluster 1 of 1 -- epic\n\n#{example}", epic_slug: "nyotes",
                                                                                       stage: "epic_plan", read: {},
                                                                                       clusters: 1, critics: 1)

    expect(result.verdict).not_to eq("unparsed")
    expect(result.must_fix + result.minor).not_to be_empty
  end
end
