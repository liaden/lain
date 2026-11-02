# frozen_string_literal: true

require "json"
require "tmpdir"

# The tool is driven over the submitter a chat really builds
# ({Lain::CLI::EpicSubmit.in_chat}), lent a real session journal, so each
# verdict below is the one `lain epic submit` would reach and lands in this
# chat's own record.
RSpec.describe Lain::Tools::EpicSubmit do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    ensure
      @chronicle&.close
    end
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@dir, "state"), "HOME" => @dir }) }
  let(:gates) { {} }
  let(:approval_timeout) { Lain::Approval::Parked::Queue::DEFAULT_TIMEOUT }
  let(:config) do
    Lain::Config.new(epics: Lain::Config::Epics.new(home: :repo, gates:), approval_timeout:)
  end
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }
  let(:store) { Lain::Dag::Factory.store }
  let(:inbox) { Lain::Frontend::Neovim::InboxView.new(store:) }
  let(:drawn) { [] }
  let(:ask_human) do
    Lain::Tools::AskHuman.new(parent: Lain::Dag::Factory.timeline(store:), observer: lambda { |event|
      lines = inbox.update(Lain::Telemetry::Message.from_event(event))
      drawn.replace(lines) unless lines.nil?
    })
  end
  let(:chronicle) { @chronicle ||= Lain::CLI::Chronicle.for(enabled: true, paths:, root: @dir) }
  let(:submitter) do
    Lain::CLI::EpicSubmit.in_chat(chronicle:, root: @dir, paths:, config:, asker: ask_human, role_spawn: nil)
  end
  let(:tool) { described_class.new(submitter:) }

  def home = Lain::Epic::Home.resolve(config:, paths:, root: @dir, slug: "frugirl-mvp")

  def submit(**input) = Sync { tool.call(input.transform_keys(&:to_s), invocation) }

  def this_sessions_decisions
    Lain::Journal.records(File.foreach(chronicle.journal_path), type: "gate_decision").to_a
  end

  def every_stage(policy) = Lain::Epic::STAGES.to_h { |stage| [stage, policy] }

  before { home.research.write("# findings\n") }

  it "asks the human through the question surfaces, and journals their approval in this session" do
    result = Sync do |task|
      call = task.async { tool.call({ "stage" => "research", "slug" => "frugirl-mvp" }, invocation) }
      task.yield until ask_human.pending?
      expect(drawn.join("\n")).to include("frugirl-mvp")
      ask_human.reply("approve", ask_human.last_question.digest)
      call.wait
    end

    expect(result).not_to be_error
    expect(result.content).to start_with("approved")
    expect(this_sessions_decisions.map { |record| record.values_at("stage", "approved", "policy") })
      .to eq([["research", true, "interactive"]])
  end

  it "puts the agent's quoted review into the question the human is asked" do
    Sync do |task|
      call = task.async do
        tool.call({ "stage" => "research", "slug" => "frugirl-mvp", "review" => "VERDICT: approve" }, invocation)
      end
      task.yield until ask_human.pending?
      expect(drawn.join("\n").delete("\n ")).to include("Reviewverdict(quotedbytheagent):", "VERDICT:approve")
      ask_human.reply("deny", ask_human.last_question.digest)
      call.wait
    end
  end

  context "when the research gate is hands_off" do
    let(:gates) { every_stage("hands_off") }

    it "approves and says the policy did" do
      result = submit(stage: "research", slug: "frugirl-mvp")

      expect(result).not_to be_error
      expect(result.content).to include("approved", "by policy hands_off")
    end

    it "does not approve the same stage twice in one chat" do
      submit(stage: "research", slug: "frugirl-mvp")
      result = submit(stage: "research", slug: "frugirl-mvp")

      expect(result.content).to include("already approved")
      expect(this_sessions_decisions.size).to eq(1)
    end

    it "refuses an epic_plan whose epic.md is missing, naming it" do
      submit(stage: "research", slug: "frugirl-mvp")
      result = submit(stage: "epic_plan", slug: "frugirl-mvp")

      expect(result).to be_error
      expect(result.content).to include(home.epic.path)
    end
  end

  context "when the research gate is deferred" do
    let(:gates) { every_stage("deferred") }

    it "says the sign-off is parked and where to review it" do
      result = submit(stage: "research", slug: "frugirl-mvp")

      expect(result.content).to include("parked", "lain epic queue frugirl-mvp")
    end
  end

  context "when a human denies over an earlier deferral of the same digest" do
    it "starts with denied" do
      parked = Lain::Epic::GateDecision.new(
        artifact_digest: Lain::Epic::Submission.research(text: "# findings\n", slug: "frugirl-mvp").digest,
        epic_slug: "frugirl-mvp", stage: "research", approved: false, answered_by: "deferred",
        policy: "deferred", latency: 1.0
      )
      FileUtils.mkdir_p(paths.filing_dir(root: @dir))
      File.open(File.join(paths.filing_dir(root: @dir), "parked.ndjson"), "w") { |io| Lain::Journal.new(io:).record(parked) }

      result = Sync do |task|
        call = task.async { tool.call({ "stage" => "research", "slug" => "frugirl-mvp" }, invocation) }
        task.yield until ask_human.pending?
        ask_human.reply("deny", ask_human.last_question.digest)
        call.wait
      end

      expect(result.content).to start_with("denied")
    end
  end

  context "when the human denies with a reason" do
    it "shows the agent that reason under denied" do
      result = Sync do |task|
        call = task.async { tool.call({ "stage" => "research", "slug" => "frugirl-mvp" }, invocation) }
        task.yield until ask_human.pending?
        ask_human.reply("deny: the summarizer question needs a benchmark first", ask_human.last_question.digest)
        call.wait
      end

      expect(result.content).to start_with("denied").and include("the summarizer question needs a benchmark first")
      expect(this_sessions_decisions.last).to include("approved" => false, "answered_by" => "human",
                                                      "reason" => "the summarizer question needs a benchmark first")
    end
  end

  context "when the human answers hold" do
    def held_with(reply)
      Sync do |task|
        call = task.async { tool.call({ "stage" => "research", "slug" => "frugirl-mvp" }, invocation) }
        task.yield until ask_human.pending?
        ask_human.reply(reply, ask_human.last_question.digest)
        call.wait
      end
    end

    it "ends the agent's turn, saying the human asked it to wait and why" do
      result = held_with("hold, I'll run the review myself")

      expect([result.ends_turn, result.error?]).to eq([true, false])
      expect(result.content).to eq("the human asked you to wait: I'll run the review myself")
      expect(this_sessions_decisions.last).to include("approved" => false, "answered_by" => "held")
    end

    it "says only that the human asked it to wait when no note came with the hold" do
      expect(held_with("wait").content).to eq("the human asked you to wait")
    end

    it "cuts a long note to 300 bytes, since the chat shows the human only these words" do
      expect(held_with("stop: #{"x" * 5000}").content).to eq("the human asked you to wait: #{"x" * 300}...")
    end

    it "cuts a multibyte note on a character boundary" do
      note = held_with("stop: a#{"日" * 200}").content.delete_prefix("the human asked you to wait: ")

      expect(note).to be_valid_encoding
      expect(note).to eq("a#{"日" * 99}...")
    end
  end

  context "when the submitted stage is adjudicated" do
    let(:gates) { every_stage("hands_off").merge("research" => "adjudicated") }

    it "refuses, naming the spike prompt a chat cannot build, and tells the agent to ask for a shell submit" do
      result = submit(stage: "research", slug: "frugirl-mvp")

      expect(result).to be_error
      expect(result.content).to include("adjudicat", "spike prompt", "lain epic submit research frugirl-mvp")
      expect(result.content).not_to include("missing brief")
    end
  end

  context "when only a later stage is adjudicated" do
    let(:gates) { every_stage("hands_off").merge("implementation" => "adjudicated") }

    it "decides the submitted stage under its own policy" do
      result = submit(stage: "research", slug: "frugirl-mvp")

      expect(result).not_to be_error
      expect(result.content).to include("approved", "by policy hands_off")
    end
  end

  context "when nobody answers within the gate's window" do
    let(:approval_timeout) { 0.3 }

    it "says the human did not answer in the approval timeout and to tell the user, not that it was denied" do
      result = submit(stage: "research", slug: "frugirl-mvp")

      expect(result.content).to include("did not answer", "0.3 seconds", "has not advanced", "tell the user")
      expect(result.content).not_to include("denied")
    end
  end

  it "says in its description that silence holds the stage and ends the turn once the window closes" do
    expect(tool.description).to include("nobody answers", "holds", "does not advance", "turn ends", "epic_submit again")
    expect(tool.description).not_to include("denies")
  end

  it "names the issue file, never a plans/ path, as what an issue_plan submits" do
    stage = tool.input_schema.dig("properties", "stage", "description")

    expect(stage).to include("issue_plan (issues/<issue>.md)")
    expect(stage).not_to include("plans/")
  end

  context "when the chat keeps no journal" do
    let(:chronicle) { Lain::CLI::Chronicle::Null.new }

    it "refuses, naming --no-journal" do
      result = submit(stage: "research", slug: "frugirl-mvp")

      expect(result).to be_error
      expect(result.content).to include("--no-journal")
    end
  end

  it "offers only the stages a chat can submit, naming them" do
    expect { submit(stage: "implementation", slug: "frugirl-mvp") }
      .to raise_error(Lain::Tool::InvalidInput, /research, epic_plan, issue_plan/)
  end

  it "refuses an issue_plan with no issue, naming the field" do
    expect { submit(stage: "issue_plan", slug: "frugirl-mvp") }
      .to raise_error(Lain::Tool::InvalidInput, /Issue can't be blank/)
  end

  it "refuses an issue_plan naming both an issue and a wave" do
    expect { submit(stage: "issue_plan", slug: "frugirl-mvp", issue: "b", wave: 2) }
      .to raise_error(Lain::Tool::InvalidInput, /issue or a wave/)
  end

  context "when the issue plans are submitted a wave at a time" do
    let(:gates) { every_stage("hands_off") }

    before do
      issues = [Lain::Epic::Issue.new(id: "a", title: "a", blocks: %w[b c]), Lain::Epic::Issue.new(id: "b", title: "b"),
                Lain::Epic::Issue.new(id: "c", title: "c")]
      home.write_epic(Lain::Epic::Graph.new(issues:))
      %w[a b c].each { |id| home.issue(id).write("prose for #{id}\n") }
      earlier = %w[research epic_plan].map do |stage|
        Lain::Epic::GateDecision.new(artifact_digest: "blake3:#{stage}", epic_slug: "frugirl-mvp", stage:,
                                     approved: true, answered_by: "hands_off", policy: "hands_off", latency: 1.0)
      end
      FileUtils.mkdir_p(paths.filing_dir(root: @dir))
      File.open(File.join(paths.filing_dir(root: @dir), "earlier.ndjson"), "w") do |io|
        journal = Lain::Journal.new(io:)
        [*earlier, Lain::Epic::StageTransition.new(epic_slug: "frugirl-mvp", stage: "issue_plan", event: "started")]
          .each { |record| journal.record(record) }
      end
    end

    context "when the issue_plan gate is adjudicated" do
      let(:gates) { every_stage("hands_off").merge("issue_plan" => "adjudicated") }

      it "relays the shell command for the same wave" do
        result = submit(stage: "issue_plan", slug: "frugirl-mvp", wave: 2)

        expect(result).to be_error
        expect(result.content).to include("lain epic submit issue_plan frugirl-mvp --wave 2")
      end
    end

    context "when nobody answers the wave's question within the window" do
      let(:gates) { every_stage("hands_off").merge("issue_plan" => "interactive") }
      let(:approval_timeout) { 0.3 }

      it "tells the agent to resubmit the same wave" do
        result = submit(stage: "issue_plan", slug: "frugirl-mvp", wave: 2)

        expect(result.content).to include(Lain::Epic::Remedy.resubmit("issue_plan", "frugirl-mvp", wave: 2))
      end
    end

    it "decides every issue in the wave in one call, one decision per issue" do
      result = submit(stage: "issue_plan", slug: "frugirl-mvp", wave: 2)

      expect(result).not_to be_error
      expect(result.content).to include("approved b", "approved c")
      expect(this_sessions_decisions.map { |record| record.values_at("issue_id", "approved") })
        .to eq([["b", true], ["c", true]])
    end
  end
end
