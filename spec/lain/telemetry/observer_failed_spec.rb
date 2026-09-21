# frozen_string_literal: true

# A raising `on_stream_started` observer must not cost #complete its
# response (see Provider::AnthropicReference/Anthropic specs for that half); this
# is the loud, attributed record of the failure instead of a swallowed one.
RSpec.describe Lain::Telemetry::ObserverFailed do
  subject(:event) { described_class.new(hook: :stream_started, digest: "blake3:req", message: "boom") }

  it "carries which observer failed, for which request, and the exception's own message" do
    expect(event.hook).to eq(:stream_started)
    expect(event.digest).to eq("blake3:req")
    expect(event.message).to eq("boom")
  end

  it "is a frozen value object, Ractor-shareable even when built from mutable Strings" do
    twin = described_class.new(hook: :stream_started, digest: +"blake3:req", message: +"boom")
    expect(event).to eq(twin)
    expect(event).to be_deeply_frozen
  end

  it "journals as an observer_failed record" do
    expect(event.to_journal).to eq(
      "type" => "observer_failed", "hook" => :stream_started, "digest" => "blake3:req", "message" => "boom"
    )
  end
end
