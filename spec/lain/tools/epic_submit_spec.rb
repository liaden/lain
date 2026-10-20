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
  let(:config) { Lain::Config.new(epics: Lain::Config::Epics.new(home: :repo, gates:)) }
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
  let(:chronicle) { @chronicle ||= Lain::CLI::Chronicle.for(enabled: true, paths:) }
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
      FileUtils.mkdir_p(paths.sessions_dir)
      File.open(File.join(paths.sessions_dir, "parked.ndjson"), "w") { |io| Lain::Journal.new(io:).record(parked) }

      result = Sync do |task|
        call = task.async { tool.call({ "stage" => "research", "slug" => "frugirl-mvp" }, invocation) }
        task.yield until ask_human.pending?
        ask_human.reply("deny", ask_human.last_question.digest)
        call.wait
      end

      expect(result.content).to start_with("denied")
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
    before { stub_const("Lain::Epic::Gate::DEFAULT_TIMEOUT", 0.2) }

    it "says nobody answered in that time and nothing advanced, not that it was denied" do
      result = submit(stage: "research", slug: "frugirl-mvp")

      expect(result.content).to include("nobody answered", "0.2 seconds", "nothing advanced")
      expect(result.content).not_to include("denied")
    end
  end

  it "says in its description that silence denies once the window closes" do
    expect(tool.description).to include("nobody answers", "denies")
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
end
