# frozen_string_literal: true

RSpec.describe Lain::Agent::TransitionListener::Null do
  it "accepts a transition and returns nil, absorbing it" do
    expect(described_class.on_transition(from: :awaiting_user, to: :awaiting_model, event: :dispatch))
      .to be_nil
  end

  it "tolerates being called with no keywords, so it never raises on a caller's shape" do
    expect { described_class.on_transition }.not_to raise_error
  end
end

RSpec.describe Lain::Agent::TransitionListener do
  it "is satisfied by anything answering on_transition with the three keywords" do
    seen = []
    listener = Class.new { define_method(:on_transition) { |**move| seen << move } }.new
    instrumentation = Lain::Agent::Instrumentation.new(transition_listener: listener)

    instrumentation.transition_listener.on_transition(from: :awaiting_model, to: :awaiting_tools, event: :tool_use)

    expect(seen).to eq([{ from: :awaiting_model, to: :awaiting_tools, event: :tool_use }])
  end

  it "names the states that mean work is in flight" do
    expect(described_class::IN_FLIGHT).to eq(awaiting_model: "model", awaiting_tools: "tool")
  end
end
