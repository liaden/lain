# frozen_string_literal: true

require "stringio"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module PolicySwitchSpecSupport
  # A recording Gate policy (`#call(effect, context) -> Boolean`): answers the
  # scripted verdict and remembers being consulted, so a spec can witness which
  # side of a flip a gated call landed on.
  class RecordingPolicy
    attr_reader :calls

    def initialize(verdict)
      @verdict = verdict
      @calls = []
    end

    def call(effect, context)
      @calls << [effect, context]
      @verdict
    end
  end
end

RSpec.describe Lain::Approval::PolicySwitch do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:queue) { PolicySwitchSpecSupport::RecordingPolicy.new(false) }
  let(:switch) { described_class.new(queue, journal:) }

  def flips
    Lain::Journal.records(journal_io.string.lines, type: "policy_switch").to_a
  end

  describe "the delegating slot (Gate's policy duck)" do
    it "answers #call through the current policy" do
      expect(switch.call("effect", "context")).to be(false)
      expect(queue.calls).to eq([%w[effect context]])
    end

    it "routes to the new policy after a switch, and the old one is never consulted again" do
      approve_all = Lain::Effect::Handler::Gate::ApproveAll.new
      switch.switch(approve_all, surface: "tty")

      expect(switch.call("effect", nil)).to be(true)
      expect(queue.calls).to be_empty
    end

    it "restores a previously held policy on a second switch" do
      switch.switch(Lain::Effect::Handler::Gate::ApproveAll.new, surface: "tty")
      switch.switch(queue, surface: "tty")

      expect(switch.call("effect", nil)).to be(false)
      expect(queue.calls.size).to eq(1)
    end

    it "exposes the current policy for a caller that must inspect the live side" do
      expect(switch.current).to be(queue)
    end
  end

  describe "the journaled flip (attributed evidence, not incident detail)" do
    it "journals each flip from/to (the model_switch symmetry) with the deciding surface" do
      switch.switch(Lain::Effect::Handler::Gate::ApproveAll.new, surface: "tty")
      switch.switch(queue, surface: "tty")

      expect(flips.map { |record| record.values_at("from", "to") })
        .to eq([%w[recording_policy approve_all], %w[approve_all recording_policy]])
      expect(flips.map { |record| record["surface"] }).to eq(%w[tty tty])
    end

    it "journals nothing at construction -- the initial policy is the wiring's, not a flip" do
      switch
      expect(flips).to be_empty
    end
  end
end
