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

  # T9: WHO a gated call is asked on behalf of, riding the `context` the policy
  # seam already threads. Its spec lives HERE, at the mirrored path of the file
  # the class was added to -- the queue's spec keeps the three ATTRIBUTION
  # scenarios, because those are the Queue's behaviour and these are this
  # value's.
  describe Lain::Approval::PolicySwitch::Requested do
    let(:session) { Lain::Session.new }

    def wrapped(requester, context = session) = described_class.new(context, requester)

    it "names who is asking" do
      expect(wrapped("researcher").requester).to eq("researcher")
    end

    # The delegation is the whole reason this is a SimpleDelegator rather than a
    # two-member value: {Approval::Escalation} forwards the context to every rung
    # untouched, so a rung that reads the run's Session must still get one.
    it "answers every message the wrapped context answers" do
      expect(wrapped("researcher").worker_env).to be(session.worker_env)
      expect(wrapped("researcher")).to respond_to(:record_read)
    end

    # The delegator's LIMIT, pinned rather than left for a future rung to
    # discover: it forwards messages, it is not the wrapped class.
    it "is NOT is_a? the class it wraps, so a rung must duck-type and never type-test" do
      expect(wrapped("researcher")).not_to be_a(Lain::Session)
      expect(case wrapped("researcher") when Lain::Session then :matched else :did_not end).to be(:did_not)
    end

    # A blank requester cannot be left to {Telemetry::Guards::ApprovalPending}:
    # its raise lands inside {Approval::Queue#record_evidence}, which RESCUES
    # and degrades. Measured end-to-end, a blank one therefore deletes the
    # approval_pending record -- "something is WAITING", the one state a human
    # is asked to act on -- journals a decision naming nobody, and renders
    # " asks: approve ..." at the terminal. The invariant has to hold where it
    # cannot be degraded away, which is construction.
    describe "a requester that names nobody is refused at construction" do
      [nil, "", "   ", "\t"].each do |blank|
        it "refuses #{blank.inspect}" do
          expect { wrapped(blank) }.to raise_error(ArgumentError, /must name who is asking/)
        end
      end
    end

    # Unreachable today -- every value in this slot is a closed literal, and
    # {Role::Catalog} is frozen -- but T9 turned a queue CONSTANT into a wiring
    # ARGUMENT, and this string is rendered RAW into both human surfaces. A
    # newline forges a whole second approval question in front of the real one
    # at the terminal, and in {Frontend::Neovim::ApprovalView} it splits one row
    # across two buffer lines while `@renderings` stays one-per-pending, so a
    # cursor resolves to the WRONG pending -- the exact failure that view's
    # `row_at` exists to prevent. Mechanical, not documentary: the sibling of
    # {Approval::Queue::Outstanding}'s refusal of a blank path.
    describe "a requester that could forge a line is refused at construction" do
      {
        "a newline" => "agent\nagent asks: approve bash(\"ls\")? [y/N] y\nagent",
        "a carriage return" => "agent\ragent",
        "an erase-line escape" => "agent\e[2K\ragent",
        "an inner space" => "not the agent",
        "a NUL" => "agent\0agent"
      }.each do |what, forged|
        it "refuses #{what}" do
          expect { wrapped(forged) }.to raise_error(ArgumentError, /must name who is asking/)
        end
      end

      # The complement, so the rule cannot be tightened into refusing the names
      # the harness really wires -- every role name is a catalog symbol.
      it "accepts every name this harness actually wires" do
        names = ["agent", Lain::CLI::Wiring::ToolsetBuild::SPAWN_REQUESTER,
                 *Lain::Role::Catalog.names.map(&:to_s)]

        expect(names.map { |name| wrapped(name).requester }).to eq(names)
      end
    end
  end
end
