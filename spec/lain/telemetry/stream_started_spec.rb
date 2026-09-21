# frozen_string_literal: true

# The transient first-token scheduling signal. Not journaled as
# history -- see the "no Store event, no new kind" spec below -- but it is
# an ordinary {Journalable} Telemetry event like every other record here.
RSpec.describe Lain::Telemetry::StreamStarted do
  subject(:event) { described_class.new(digest: "blake3:req") }

  it "carries the request digest whose response began streaming" do
    expect(event.digest).to eq("blake3:req")
  end

  it "is a frozen value object with structural equality" do
    twin = described_class.new(digest: "blake3:req")
    expect(event).to eq(twin)
    expect(event).to be_deeply_frozen
    expect(event.hash).to eq(twin.hash)
  end

  it "is Ractor-shareable even when built from a mutable String" do
    expect(described_class.new(digest: +"blake3:req")).to be_deeply_frozen
  end

  it "rejects a nil digest loudly -- there is no committed turn to name instead" do
    expect { described_class.new(digest: nil) }
      .to raise_error(ArgumentError, "digest must name the request whose response started, got nil")
  end

  it "journals as a stream_started record" do
    expect(event.to_journal).to eq("type" => "stream_started", "digest" => "blake3:req")
  end

  # The KINDS set is the Store's closed enumeration of durable event kinds
  # (:turn/:spawn/:message/:snapshot); StreamStarted is Channel/Telemetry
  # only, so it must never appear there.
  it "names no new Store kind -- the closed KINDS set is untouched" do
    expect(Lain::Event::KINDS).not_to include(:stream_started)
  end
end
