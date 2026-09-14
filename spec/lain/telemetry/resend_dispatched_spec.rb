# frozen_string_literal: true

# The dispatch marker: the record TYPE that says a hand-edited resend was
# handed to the loop for dispatch. Emitted by CLI::ResendBridge attempt-first
# (before Agent#run), so a dispatch the wire then failed still reads as
# attempted; `digest` is the edited request's content address -- the join key
# onto BOTH the request_resent projection and the ordinary request_sent the
# wire path journals when the loop actually sends it.
RSpec.describe Lain::Telemetry::ResendDispatched do
  subject(:event) { described_class.new(digest: "blake3:edited") }

  it "journals under its own discriminator, carrying the join-key digest" do
    expect(event.journal_type).to eq("resend_dispatched")
    expect(event.to_journal).to eq("type" => "resend_dispatched", "digest" => "blake3:edited")
  end

  it "must name the resent request it dispatched" do
    expect { described_class.new(digest: nil) }
      .to raise_error(ArgumentError, /must name the resent request it dispatched, got nil/)
  end

  it "is deeply frozen and Ractor-shareable" do
    expect(event).to be_deeply_frozen
  end
end
