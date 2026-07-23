# frozen_string_literal: true

require "stringio"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module YoloSpecSupport
  # The queue side of the flip: Gate's policy duck, recording consultation --
  # what "/yolo off" must restore and "/yolo on" must stop consulting. Answers
  # the queue's read duck too (nothing parked), like the real Approval::Queue.
  class RecordingQueue
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(effect, context)
      @calls << [effect, context]
      false
    end

    def each(&block) = [].each(&block)
  end

  # The minimal effect a {Approval::Queue::Pending} reads: a name and an input.
  Effect = Struct.new(:name, :input)
end

RSpec.describe Lain::CLI::Command::Yolo do
  subject(:yolo) { described_class.new }

  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:queue) { YoloSpecSupport::RecordingQueue.new }
  let(:switch) { Lain::Approval::PolicySwitch.new(queue, journal:) }
  let(:env) { instance_double(Lain::CLI::Command::Env, policy_switch: switch, approvals: queue) }

  def flips
    Lain::Journal.records(journal_io.string.lines, type: "policy_switch").to_a
  end

  it "registers as /yolo with a one-line usage" do
    expect(yolo.name).to eq("yolo")
    expect(yolo.usage).to include("/yolo")
  end

  describe "/yolo on" do
    it "flips the live gate: subsequent gated calls pass without prompting" do
      yolo.call("on", env)

      expect(switch.call("effect", nil)).to be(true)
      expect(queue.calls).to be_empty
    end

    it "returns rendered text, never printing" do
      text = nil
      expect { text = yolo.call("on", env) }.not_to output.to_stdout
      expect(text).to be_a(String).and include("yolo")
    end

    it "counts parked pendings in the confirmation -- they stay fail-closed until /approve drains them" do
      parked = Array.new(2) do
        Lain::Approval::Queue::Pending.new(effect: YoloSpecSupport::Effect.new("bash", {}),
                                           requester: "agent", clock: -> { 0.0 })
      end
      crowded = instance_double(Lain::CLI::Command::Env, policy_switch: switch, approvals: parked)

      expect(yolo.call("on", crowded)).to include("2 parked approvals remain").and include("/approve")
    end
  end

  describe "/yolo off" do
    it "restores the queue: gated calls consult it again" do
      yolo.call("on", env)
      yolo.call("off", env)

      expect(switch.call("effect", nil)).to be(false)
      expect(queue.calls.size).to eq(1)
    end

    it "refuses loudly when no queue was ever wired (a --yolo session)" do
      bare = instance_double(Lain::CLI::Command::Env, policy_switch: switch,
                                                      approvals: Lain::CLI::Command::Env::YoloApprovals)

      expect { yolo.call("off", bare) }.to raise_error(Lain::Error, /queue/)
    end
  end

  it "journals each flip as an attributed event" do
    yolo.call("on", env)
    yolo.call("off", env)

    expect(flips.map { |record| record["surface"] }).to eq(%w[tty tty])
    expect(flips.map { |record| record["to"] }).to eq(%w[approve_all recording_queue])
  end

  it "refuses an argument that is neither on nor off, naming the usage" do
    expect { yolo.call("sideways", env) }.to raise_error(Lain::Error, %r{/yolo on\|off})
    expect { yolo.call("", env) }.to raise_error(Lain::Error, %r{/yolo on\|off})
  end
end
