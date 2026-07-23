# frozen_string_literal: true

# T22: the read-mostly binding /ruby inspects the live conversation through.
# It exposes exactly the four collaborators the card names -- timeline,
# session, supervisor, status -- as reader messages, and hands out a Ruby
# Binding whose `self` is this object so an inspected expression resolves
# those names and nothing wider. The object is frozen, so the console cannot
# reassign its ivars (read-mostly is mechanical, not a convention).
RSpec.describe Lain::CLI::InspectionBinding do
  let(:timeline) { double("timeline", head: "blake3:abc") }
  let(:session) { double("session", reminders: []) }
  let(:supervisor) { double("supervisor") }
  let(:status) { double("status") }

  subject(:inspection) { described_class.new(timeline:, session:, supervisor:, status:) }

  it "exposes the four collaborators as readers" do
    expect(inspection.timeline).to be(timeline)
    expect(inspection.session).to be(session)
    expect(inspection.supervisor).to be(supervisor)
    expect(inspection.status).to be(status)
  end

  it "is frozen, so the inspecting console cannot reassign its state" do
    expect(inspection).to be_frozen
  end

  describe "#context" do
    it "is a Binding whose self resolves the collaborators by name" do
      context = inspection.context

      expect(context).to be_a(Binding)
      expect(context.eval("timeline")).to be(timeline)
      expect(context.eval("session")).to be(session)
      expect(context.eval("supervisor")).to be(supervisor)
      expect(context.eval("status")).to be(status)
    end

    it "evaluates a message sent to a collaborator" do
      expect(inspection.context.eval("timeline.head")).to eq("blake3:abc")
    end

    it "resolves nothing wider than the four readers" do
      expect { inspection.context.eval("agent") }.to raise_error(NameError)
    end
  end

  describe ".for(env)" do
    it "reads timeline and session off the agent, supervisor and status off the env" do
      agent = double("agent", timeline:, session:)
      env = double("env", agent:, supervisor:, status:)

      inspection = described_class.for(env)

      expect(inspection.context.eval("timeline")).to be(timeline)
      expect(inspection.context.eval("session")).to be(session)
      expect(inspection.context.eval("supervisor")).to be(supervisor)
      expect(inspection.context.eval("status")).to be(status)
    end
  end
end
