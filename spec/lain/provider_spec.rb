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

  # A provider with no window knowledge answers nil. Deliberately NOT
  # a NotImplementedError like #capabilities/#cache_profile: those two are
  # facts every arm KNOWS and must state, while "how many tokens can this model
  # take here" is a question most providers genuinely cannot answer -- the
  # window comes from a book, not from the wire. nil is the honest answer, and
  # it is what keeps ContextWindow's conservative fallback in play.
  describe "#context_window_tokens" do
    it "answers nil from the abstract surface, so the conservative fallback stands" do
      expect(described_class.new.context_window_tokens("claude-opus-4-8")).to be_nil
    end

    it "answers nil for a concrete provider that does not implement it" do
      expect(Lain::Provider::Mock.new.context_window_tokens("m")).to be_nil
    end
  end

  # Where a run's models are served, which a caller deciding how much work to
  # put through one has to be able to ask of anything answering the Provider
  # duck. "Nobody said" is an answer that already has a reading -- hosted --
  # rather than a hole a caller has to guard.
  describe "#admission_endpoint" do
    it "names no endpoint from the abstract surface" do
      expect(described_class.new.admission_endpoint).to be_nil
    end

    it "names no endpoint for a provider that dials nothing" do
      expect(Lain::Provider::Mock.new.admission_endpoint).to be_nil
    end
  end

  # The typed form of the same question, which a window book needs because
  # "nothing is resident" and "nobody answered" cost differently to ask again.
  # A provider with no server to ask can never be unreachable, so the base
  # answers from {#context_window_tokens} and an override of that still counts.
  describe "#window_probe" do
    it "answers nothing resident from the abstract surface" do
      expect(described_class.new.window_probe("claude-opus-4-8")).to equal(Lain::Provider::WindowProbe::NONE_RESIDENT)
    end

    it "answers a resident window from a provider that overrides the untyped question" do
      provider = Class.new(Lain::Provider::Mock) { def context_window_tokens(_model) = 32_768 }.new

      expect(provider.window_probe("m")).to eq(Lain::Provider::WindowProbe.resident(32_768))
      expect(provider.window_probe("m").window_tokens).to eq(32_768)
    end

    it "answers values that are frozen and shareable" do
      probes = [Lain::Provider::WindowProbe.resident(8_192), Lain::Provider::WindowProbe::NONE_RESIDENT,
                Lain::Provider::WindowProbe::UNREACHABLE]

      expect(probes).to all(satisfy { |probe| Ractor.shareable?(probe) })
      expect(probes.map(&:unreachable?)).to eq([false, false, true])
    end
  end

  # Whether a server can answer for a model, asked before anything is spent on
  # it. A provider with no server to ask cannot say either way.
  describe "#serves?" do
    it "answers unknown from the abstract surface" do
      expect(described_class.new.serves?("claude-haiku-4-5")).to equal(Lain::Provider::Serving::UNKNOWN)
    end

    it "answers three values that are frozen, shareable and told apart" do
      answers = [Lain::Provider::Serving::SERVED, Lain::Provider::Serving::NOT_SERVED,
                 Lain::Provider::Serving::UNKNOWN]

      expect(answers).to all(satisfy { |answer| Ractor.shareable?(answer) })
      expect(answers.map(&:not_served?)).to eq([false, true, false])
      expect(answers.uniq.size).to eq(3)
    end
  end

  # to_s is the human-facing capability list; inspect keeps the class-tagged,
  # debug-oriented form -- the DegradedSet convention (see
  # capability/degraded_set_spec.rb). Uses Provider::Mock because the abstract
  # base raises on #capabilities.
  describe "string conversions" do
    subject(:provider) { Lain::Provider::Mock.new(capabilities: %i[thinking streaming]) }

    it "renders to_s as the sorted, joined capability list, untagged" do
      expect(provider.to_s).to eq("streaming, thinking")
    end

    it_behaves_like "a class-tagged inspect"
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
