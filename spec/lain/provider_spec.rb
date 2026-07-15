# frozen_string_literal: true

RSpec.describe Lain::Provider do
  describe "the abstract seam" do
    subject(:provider) { described_class.new }

    it "refuses to guess its capabilities" do
      expect { provider.capabilities }.to raise_error(NotImplementedError, /must declare/)
    end

    it "refuses to encode" do
      expect { provider.encode(nil) }.to raise_error(NotImplementedError, /#encode/)
    end

    it "refuses to complete" do
      expect { provider.complete(nil) }.to raise_error(NotImplementedError, /#complete/)
    end
  end

  # Naming every capability in one place is what lets Compare refuse to compare
  # two runs whose degraded sets differ.
  describe "CAPABILITIES" do
    it "names the tactics a context strategy can depend on" do
      expect(described_class::CAPABILITIES)
        .to include(:streaming, :prompt_caching, :strict_tools, :thinking, :parallel_tool_use)
    end
  end

  describe "capability checks" do
    let(:limited) { Lain::Provider::Mock.new(capabilities: %i[streaming]) }

    it "answers supports?" do
      expect(limited.supports?(:streaming)).to be(true)
      expect(limited.supports?(:prompt_caching)).to be(false)
    end

    # A degraded bench run must say which arm lost the tactic, not fail silently.
    it "names the provider when a required capability is absent" do
      expect { limited.require!(:prompt_caching) }
        .to raise_error(described_class::Unsupported, /Mock does not support :prompt_caching/)
    end

    it "passes when the capability is present" do
      expect(limited.require!(:streaming)).to be(true)
    end
  end
end

RSpec.describe Lain::Provider::Mock do
  let(:request) do
    Lain::Request.new(model: "m", messages: [{ "role" => "user", "content" => [] }], max_tokens: 8)
  end

  let(:response) { Lain::Response.new(content: [], stop_reason: :end_turn) }

  it "records the requests it was given, in order" do
    provider = described_class.new(responses: [response])
    provider.complete(request)
    expect(provider.requests).to eq([request])
    expect(provider.last_request).to eq(request)
    expect(provider.call_count).to eq(1)
  end

  it "returns responses in order and then repeats the last" do
    first = Lain::Response.new(content: [], stop_reason: :tool_use)
    provider = described_class.new(responses: [first, response])

    expect(provider.complete(request)).to stop_with(:tool_use)
    expect(provider.complete(request)).to stop_with(:end_turn)
    expect(provider.complete(request)).to stop_with(:end_turn)
  end

  it "raises rather than returning nil when it has nothing to say" do
    expect { described_class.new.complete(request) }.to raise_error(Lain::Error, /ran out of responses/)
  end

  it "encodes without touching a network" do
    expect(described_class.new.encode(request)).to eq(request.cache_payload)
  end
end
