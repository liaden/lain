# frozen_string_literal: true

require "tmpdir"

module AdjudicationSpecSupport
  # The three things the pair reads off a {Lain::CLI::Backend}, and nothing
  # else -- so a spec never needs an API key to build one.
  FakeBackend = Data.define(:provider, :context, :slots)
end

# The adjudication pair -- a role spawn and a brief -- is what an `adjudicated`
# gate needs and nothing else does. `lain epic submit` builds it out of chat,
# from the same backend flags a chat reads, and ONLY when some stage is
# configured `adjudicated`: a session gating everything interactively never
# constructs a provider, so it never needs a key.
RSpec.describe Lain::CLI::EpicSubmit::Adjudication do
  around do |example|
    Dir.mktmpdir do |tmp|
      @tmp = tmp
      example.run
    end
  end

  def root = @tmp
  def paths = @paths ||= Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@tmp, "state"), "HOME" => @tmp })
  def config(gates) = Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg, gates:))
  def interactive = Lain::Epic::STAGES.to_h { |stage| [stage, "interactive"] }
  def adjudicating = interactive.merge("research" => "adjudicated")

  def backend(*answers)
    AdjudicationSpecSupport::FakeBackend.new(
      provider: Lain::Provider::Mock.new(responses: answers.map { |answer| text_response(answer) }),
      context: Lain::Context.new(model: "judge", max_tokens: 256), slots: Lain::Prompt::Slots.load(root:)
    )
  end

  def pair(gates = adjudicating, backend: -> { backend("the evidence") }, **seam)
    described_class.pair(config: config(gates), paths:, root:, backend:, **seam)
  end

  def text_of(result)
    content = result.content
    content.is_a?(String) ? content : content.filter_map { |block| block["text"] }.join("\n")
  end

  describe "built lazily" do
    # Scenario: unadjudicated stages build no backend
    it "builds no backend when no stage is adjudicated" do
      built = pair(interactive, backend: -> { raise "a backend was built for a session with nothing to adjudicate" })

      expect(built).to eq(described_class::NONE)
      expect([built.role_spawn, built.brief]).to eq([nil, nil])
    end

    it "builds its backend exactly once when any stage is adjudicated" do
      calls = 0
      pair(adjudicating, backend: -> { (calls += 1) && backend("the evidence") })

      expect(calls).to eq(1)
    end
  end

  describe "the role spawn" do
    it "spawns an out-of-chat child over the backend's provider" do
      result = pair.role_spawn.call(:researcher, :fresh, "gather evidence on the research")

      expect(result).to be_ok
      expect(text_of(result)).to eq("the evidence")
    end

    it "serves the verdict role too, whose tools the same union must hold" do
      result = pair(backend: -> { backend("APPROVE") }).role_spawn.call(:gate_adjudicator, :fresh, "judge it")

      expect(text_of(result)).to eq("APPROVE")
    end

    # A child spawned here gets no tool middleware from any chat, so the guard
    # its reads go through must be HANDED IN -- and the spawn seam is where a
    # guard reaches a child. Every further seam member is forwarded verbatim.
    it "forwards further spawn-seam members, which is where a guard is handed in" do
      marker = Object.new

      expect(pair(gate_policy: marker).role_spawn.seam.gate_policy).to be(marker)
    end

    it "refuses a seam member the spawn seam does not carry, naming it" do
      expect { pair(tool_middlewere: Object.new) }.to raise_error(ArgumentError, /tool_middlewere/)
    end
  end

  # The forwarded members are checked on EVERY path: a typo that only raised
  # once some stage was adjudicated would wait for the night it mattered.
  describe "the seam members it forwards" do
    it "refuses a misspelt member even when nothing is adjudicated" do
      expect { pair(interactive, backend: -> { raise "built a backend" }, tool_middlewere: :guard) }
        .to raise_error(ArgumentError, /tool_middlewere/)
    end

    %i[provider context_factory parent].each do |owned|
      it "refuses #{owned}, which the pair sets itself" do
        expect { pair(owned => :smuggled) }.to raise_error(ArgumentError, /#{owned}/)
      end
    end
  end

  # The researcher reads files; nothing on the gate's artifact duck maps a
  # digest to a path, so the brief is what tells the spike where to look.
  describe Lain::CLI::EpicSubmit::Adjudication::Brief do
    subject(:brief) { described_class.new(config: config(adjudicating), paths:, root:) }

    def home = Lain::Epic::Home.resolve(config: config(adjudicating), paths:, root:, slug: "demo")

    it "sends a research spike to the research document" do
      prompt = brief.call(Lain::Epic::Submission.research(text: "notes\n", slug: "demo"))

      expect(prompt).to include("research", "\"demo\"", home.research.path)
    end

    it "sends an issue plan's spike to the plan and to the epic that holds its criteria" do
      submission = Lain::Epic::Submission.issue_plan(text: "plan\n", slug: "demo", issue_id: "a", criteria_digest: nil)

      expect(brief.call(submission)).to include("issue a", home.plan("a").path, home.epic.path)
    end

    it "names an implementation's changeset by its address, beside the plan it was built to" do
      submission = Lain::Epic::Submission.implementation(slug: "demo", issue_id: "a", digest: "blake3:change")

      expect(brief.call(submission)).to include("blake3:change", home.plan("a").path)
    end

    it "tells the spike to gather rather than judge" do
      expect(brief.call(Lain::Epic::Submission.research(text: "notes\n", slug: "demo"))).to match(/do not judge/i)
    end
  end
end
