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
