# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::CLI::Command::Goal do
  subject(:goal) { described_class.new(driver:) }

  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:driver) { Lain::CLI::GoalDriver.new(journal:) }

  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 256) }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:provider) { Lain::Provider::Mock.new(responses: [text_response("working on it")]) }
  let(:session) { Lain::Session.new }
  let(:agent) { Lain::Agent.new(provider:, toolset:, context:, session:) }
  let(:env) { instance_double(Lain::CLI::Command::Env, agent:) }

  def text_of(turn)
    turn.content.select { |block| block["type"] == "text" }.map { |block| block["text"] }.join
  end

  # The Repl's converse loop, one driven turn: poll the driver, feed the prompt
  # it answers back through #ask exactly as `next_text` does, then poll again.
  # That SECOND poll is the first moment the objective's turn is on the chain.
  def drive_once
    prompt = driver.poll(agent.timeline)
    agent.ask(prompt) if prompt
    driver.poll(agent.timeline)
  end

  it "registers as /goal with a one-line usage" do
    expect(goal.name).to eq("goal")
    expect(goal.usage).to include("/goal")
  end

  describe "/goal <objective>" do
    it "sets the standing goal on the driver and confirms it, naming the objective" do
      text = goal.call("make the specs green", env)

      expect(driver).to be_active
      expect(text).to be_a(String).and include("make the specs green")
    end

    it "returns rendered text, never printing" do
      text = nil
      expect { text = goal.call("make the specs green", env) }.not_to output.to_stdout

      expect(text).to be_a(String)
    end
  end

  describe "/goal off" do
    it "clears the standing goal and confirms it inline" do
      goal.call("make the specs green", env)
      text = goal.call("off", env)

      expect(driver).not_to be_active
      expect(text).to be_a(String).and match(/off/i)
    end
  end

  describe "bare /goal" do
    it "reports no standing goal when idle" do
      expect(goal.call("", env)).to match(/no.*goal|none|idle/i)
    end

    it "reports the objective in force when driving" do
      goal.call("make the specs green", env)

      expect(goal.call("", env)).to include("make the specs green")
    end
  end

  # B3, AC1 as amended after the escalation: the objective's turn is pinned
  # ONCE IT ENTERS THE TIMELINE, not when `/goal` is dispatched. At dispatch the
  # command runs lib-side with zero commits, so the head still names the
  # PREVIOUS topic's turn -- pinning that would protect noise forever and let
  # the objective be elided, the exact inverse of the point.
  describe "auto-pinning the objective (B3)" do
    it "pins nothing at dispatch: the objective's turn does not exist yet" do
      agent.ask("an unrelated earlier question")
      stale_head = agent.timeline.head_digest

      goal.call("ship the parser", env)

      expect(session.pins).to be_empty
      expect(session).not_to be_pinned(stale_head)
    end

    # Read back through the Timeline rather than trusting the digest: the pin
    # is only right if the turn it names actually carries the objective.
    it "pins the turn carrying the objective once the driver has re-prompted with it" do
      goal.call("ship the parser", env)

      drive_once

      pinned = agent.timeline.ancestors.select { |turn| session.pinned?(turn.digest) }
      expect(pinned.size).to eq(1)
      expect(pinned.first.role).to eq("user")
      expect(text_of(pinned.first)).to include("ship the parser")
    end

    it "leaves the pin in place when the goal is cleared" do
      goal.call("ship the parser", env)
      drive_once
      pinned = session.pins
      expect(pinned.size).to eq(1)

      goal.call("off", env)

      expect(driver).not_to be_active
      expect(session.pins).to eq(pinned)
    end

    context "with no live driver (GoalDriver::Null)" do
      let(:driver) { Lain::CLI::GoalDriver::Null }

      it "returns the existing unavailable message and pins nothing" do
        text = goal.call("ship the parser", env)

        expect(text).to eq("goal driving is unavailable in this session")
        expect(session.pins).to be_empty
      end
    end
  end
end
