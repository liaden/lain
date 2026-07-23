# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::CLI::Command::Goal do
  subject(:goal) { described_class.new(driver:) }

  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:driver) { Lain::CLI::GoalDriver.new(journal:) }
  let(:env) { instance_double(Lain::CLI::Command::Env) }

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
end
