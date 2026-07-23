# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::CLI::GoalDriver do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 256) }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }

  def iterations
    Lain::Journal.records(journal_io.string.lines, type: "goal_iteration").to_a
  end

  # A Timeline whose head is a settled assistant turn carrying `text` -- the
  # marker source the driver reads between asks, without standing up an Agent.
  def settled_with(text)
    Lain::Timeline.empty
                  .commit(role: :user, content: [{ "type" => "text", "text" => "go" }])
                  .commit(role: :assistant, content: [{ "type" => "text", "text" => text }])
  end

  describe "a Null driver (no standing goal)" do
    subject(:driver) { described_class.new(journal:) }

    it "is inactive and answers the poll with nothing to do, cheaply and silently" do
      notices = []

      expect(driver).not_to be_active
      expect(driver.poll(settled_with("anything")) { |n| notices << n }).to be_nil
      expect(notices).to be_empty
      expect(iterations).to be_empty
    end
  end

  describe "goal loops until done-signal" do
    subject(:driver) { described_class.new(journal:) }

    # A real Agent over a Provider::Mock scripting two continue turns then an
    # explicit done marker -- faithful to the AC.
    let(:provider) do
      Lain::Provider::Mock.new(responses: [text_response("still working"),
                                           text_response("more to do"),
                                           text_response("all specs pass -- #{described_class::DONE}")])
    end
    let(:agent) { Lain::Agent.new(provider:, toolset:, context:) }

    # Mirrors the Repl's converse loop: poll the driver between asks, feed each
    # returned prompt to the agent, stop when the driver has nothing more.
    def drive(driver, agent)
      notices = []
      prompt = driver.poll(agent.timeline) { |n| notices << n }
      while prompt
        agent.ask(prompt)
        prompt = driver.poll(agent.timeline) { |n| notices << n }
      end
      notices
    end

    it "re-prompts with the goal plus a continue/done instruction after each settled turn" do
      driver.start("make the specs green")
      first = driver.poll(agent.timeline)

      expect(first).to include("make the specs green").and include(described_class::DONE)
    end

    it "stops on the marker, driving exactly the scripted turns" do
      driver.start("make the specs green")
      notices = drive(driver, agent)

      expect(provider.call_count).to eq(3)
      expect(driver).not_to be_active
      expect(notices.join).to match(/reached|complete|done/i)
    end

    it "journals each iteration as a goal-attributed event" do
      driver.start("make the specs green")
      drive(driver, agent)

      expect(iterations.size).to eq(3)
      expect(iterations.map { |r| r["goal"] }.uniq).to eq(["make the specs green"])
      expect(iterations.map { |r| r["surface"] }.uniq).to eq(["goal"])
    end
  end

  describe "hard stops" do
    let(:unfinished) { settled_with("continuing to work") }

    it "stops on /goal off, going idle without driving another turn" do
      driver = described_class.new(journal:)
      driver.start("make the specs green")
      driver.stop

      expect(driver).not_to be_active
      expect(driver.poll(unfinished)).to be_nil
      expect(iterations).to be_empty
    end

    it "stops at the iteration cap (default 5), reporting the ceiling inline" do
      driver = described_class.new(journal:)
      driver.start("make the specs green")
      notices = []
      prompts = Array.new(6) { driver.poll(unfinished) { |n| notices << n } }

      expect(prompts.compact.size).to eq(5)
      expect(iterations.size).to eq(5)
      expect(driver).not_to be_active
      expect(notices.join).to match(/5/)
    end

    it "honours a lower cap" do
      driver = described_class.new(journal:, cap: 2)
      driver.start("make the specs green")
      prompts = Array.new(4) { driver.poll(unfinished) }

      expect(prompts.compact.size).to eq(2)
    end

    it "stops on a budget interrupt, reporting it inline" do
      driver = described_class.new(journal:)
      driver.start("make the specs green")
      driver.poll(unfinished)
      driver.interrupt

      notices = []
      expect(driver.poll(unfinished) { |n| notices << n }).to be_nil
      expect(driver).not_to be_active
      expect(notices.join).to match(/interrupt/i)
    end
  end

  describe "quiescence (only the observable half is wired -- see handback)" do
    it "defers -- drives nothing, stays active -- while a parked approval blocks the fleet" do
      open = false
      driver = described_class.new(journal:, quiescent: -> { open })
      driver.start("make the specs green")

      expect(driver.poll(settled_with("continuing"))).to be_nil
      expect(driver).to be_active
      expect(iterations).to be_empty

      open = true
      expect(driver.poll(settled_with("continuing"))).to be_a(String)
      expect(iterations.size).to eq(1)
    end
  end
end
