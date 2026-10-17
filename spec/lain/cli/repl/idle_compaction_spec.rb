# frozen_string_literal: true

require "async"
require "stringio"

RSpec.describe Lain::CLI::Repl::IdleCompaction do
  let(:sink) { StringIO.new }

  # A non-verifying double on purpose: prepare_idle is the Agent's, and this
  # surface only asks it.
  def agent_answering(*answers)
    calls = []
    agent = Object.new
    agent.define_singleton_method(:prepare_idle) do
      calls << :asked
      answer = answers.size > 1 ? answers.shift : answers.first
      raise answer if answer.is_a?(Exception)

      answer
    end
    [agent, calls]
  end

  describe ".for" do
    it "builds the ticking surface for the idle schedule" do
      agent, = agent_answering(false)

      expect(described_class.for("idle", agent:, sink:)).to be_a(described_class)
    end

    it "builds Never for the turn schedule, which spawns nothing and never asks the agent" do
      agent, calls = agent_answering(false)
      surface = described_class.for("turn", agent:, sink:)

      Sync { |task| surface.spawn(task).stop }

      expect([surface, calls]).to eq([described_class::Never, []])
    end
  end

  describe "#spawn" do
    it "asks the agent once per tick and sleeps TICK seconds before each" do
      agent, calls = agent_answering(false)
      slept = []
      sleeper = lambda do |seconds|
        slept << seconds
        Async::Task.current.stop if slept.size > 3
      end
      surface = described_class.new(agent:, sink:, sleeper:)

      Sync { |task| surface.spawn(task).wait }

      expect([calls.size, slept.uniq]).to eq([3, [described_class::TICK]])
    end

    it "can be stopped while it sleeps, and no tick fires after" do
      agent, calls = agent_answering(false)
      surface = described_class.new(agent:, sink:, sleeper: ->(seconds) { Async::Task.current.sleep(seconds) })

      Sync do |task|
        running = surface.spawn(task)
        task.yield
        running.stop
        task.sleep(0.01)

        expect([running.running?, calls]).to eq([nil, []])
      end
    end
  end

  describe "#tick" do
    it "writes a raised fault to the sink and survives to ask again" do
      agent, calls = agent_answering(RuntimeError.new("summarizer down"), false)
      surface = described_class.new(agent:, sink:)

      surface.tick
      surface.tick

      expect([calls.size, sink.string]).to match([2, /RuntimeError.*summarizer down/])
    end

    it "does nothing else when the agent declines because it is dispatching" do
      agent, calls = agent_answering(false)

      described_class.new(agent:, sink:).tick

      expect([calls.size, sink.string]).to eq([1, ""])
    end
  end
end
