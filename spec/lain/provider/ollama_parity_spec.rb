# frozen_string_literal: true

# Provider::Ollama against the SAME seven-gate group Mock and Anthropic pass
# -- a new backend cannot land half-working. The canned Responses are replayed
# through the REAL Ollama decode (OllamaWire serializes them into `/api/chat`
# bodies), so every gate exercises the actual content reassembly, tool-call
# handling, and stop_reason normalization rather than a stub of the provider's
# own logic.
RSpec.describe Lain::Provider::Ollama do
  include_examples "a Lain::Provider",
                   provider_factory: lambda { |responses|
                     described_class.new(transport: OllamaWire.queue_transport(responses))
                   }

  # The design plan's own gate: "a new backend cannot land half-working." The
  # cloud deployment shares the local arm's encoder and decoder end to end, so
  # this group is expected to pass UNCHANGED against `.cloud` -- which is
  # exactly why it is worth running: if it does not, something
  # deployment-shaped has reached the wire path, which is the one thing this
  # chunk promised it would not do.
  #
  # `.cloud` builds a real `Deployment::Cloud` (a false `#local?`, no
  # loaded-runner probing, a Bearer header the deployment declares) over the
  # SAME `OllamaWire` double the group above uses -- the real decode path, no
  # cassette, and no network reachable on this default-on spec either way.
  describe "against a cloud deployment" do
    include_examples "a Lain::Provider",
                     provider_factory: lambda { |responses|
                       described_class.cloud(api_key: "test-key", transport: OllamaWire.queue_transport(responses))
                     }
  end

  # NOT evidence that deployment-shaped state cannot reach the wire -- it is a
  # construction guarantee, and it is worth being honest about which. Ollama's
  # #encode takes no deployment argument at all (see Encoding), so
  # byte-identity holds BY CONSTRUCTION rather than by anything this example
  # measures. It earns its place as a regression PIN, not as proof: it goes
  # red the instant anyone threads deployment-shaped state into the encoder,
  # which today is the only way this claim could become false.
  describe "encoding" do
    it "is byte-identical across deployments for the same request" do
      request = Lain::Request.new(
        model: "m", max_tokens: 8, system: "be terse",
        tools: [{ name: "t", description: "d", input_schema: { type: :object, properties: {}, required: [] } }],
        messages: [{ "role" => "user", "content" => [{ "type" => "text", "text" => "hi" }] }]
      )
      local = described_class.new(transport: OllamaWire.queue_transport([]))
      cloud = described_class.cloud(api_key: "test-key", transport: OllamaWire.queue_transport([]))

      expect(Lain::Canonical.dump(local.encode(request))).to eq(Lain::Canonical.dump(cloud.encode(request)))
    end
  end
end
