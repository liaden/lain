# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::SessionShared do
  subject(:event) { described_class.new(url: "https://gist.github.com/u/abc", format: :html, masked: 3) }

  it "carries the url, the format and the masked count" do
    expect(event).to have_attributes(url: "https://gist.github.com/u/abc", format: "html", masked: 3)
  end

  it "journals byte for byte as a session_shared record" do
    expect(JSON.generate(event.to_journal)).to eq(
      '{"type":"session_shared","url":"https://gist.github.com/u/abc","format":"html","masked":3}'
    )
  end

  it "is deeply frozen when built from mutable input" do
    expect(described_class.new(url: +"https://gist.github.com/u/abc", format: +"html", masked: 0)).to be_deeply_frozen
  end

  it "refuses a missing url, naming it" do
    expect { described_class.new(format: :html, masked: 0) }.to raise_error(ArgumentError, /url/)
  end
end
