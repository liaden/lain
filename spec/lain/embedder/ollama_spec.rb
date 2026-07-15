# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe Lain::Embedder::Ollama do
  # A transport double returning a scripted body, for decode-focused examples --
  # mirrors the injected-transport idiom in spec/lain/provider/ollama_spec.rb.
  def transport_embed(body)
    Class.new do
      define_method(:embed_post) { |_payload| Struct.new(:body).new(body) }
    end.new
  end

  def embed_body(*vectors)
    { "model" => described_class::DEFAULT_MODEL, "embeddings" => vectors,
      "total_duration" => 12_345, "load_duration" => 6789, "prompt_eval_count" => 2 }
  end

  describe "#embed batch" do
    # AC: batch embed -- two texts in, two equal-dimension Float vectors out.
    it "returns one Float vector per text, all of equal dimension" do
      provider = described_class.new(transport: transport_embed(embed_body([0.1, 0.2, 0.3], [0.4, 0.5, 0.6])))

      vectors = provider.embed(%w[a b])

      expect(vectors.size).to eq(2)
      expect(vectors.map(&:size).uniq).to eq([3])
      expect(vectors.flatten).to all(be_a(Float))
    end

    it "sends {model:, input:} to the transport, defaulting to the pinned model" do
      provider = described_class.new(transport: (recorder = capturing_transport))

      provider.embed(%w[a b])

      expect(recorder.payload).to eq(model: described_class::DEFAULT_MODEL, input: %w[a b])
    end

    it "honors an injected model over the default" do
      provider = described_class.new(model: "mxbai-embed-large", transport: (recorder = capturing_transport))

      provider.embed(%w[a])

      expect(recorder.payload[:model]).to eq("mxbai-embed-large")
    end

    # Probe finding: JSON parses a decimal-less component as Integer, so a wire
    # value of 0 or 1 is a legitimate embedding component, not a torn body.
    it "accepts an integer-valued component (JSON parses 0 as Integer, not Float)" do
      provider = described_class.new(transport: transport_embed(embed_body([0])))

      expect(provider.embed(%w[a])).to eq([[0]])
    end

    it "accepts a mixed Integer/Float vector" do
      provider = described_class.new(transport: transport_embed(embed_body([1, 0.5])))

      expect(provider.embed(%w[a])).to eq([[1, 0.5]])
    end
  end

  # AC: failures are loud -- never a silent empty vector. Every malformed body is
  # a named Lain error, so a caller can never mistake a broken response for a
  # legitimately empty embedding.
  describe "#embed failures are loud" do
    it "raises when the embeddings key is absent, rather than returning []" do
      provider = described_class.new(transport: transport_embed({ "model" => "nomic-embed-text" }))

      expect { provider.embed(%w[a b]) }.to raise_error(Lain::Embedder::Ollama::APIError, /embeddings/)
    end

    it "raises when the vector count does not match the input count" do
      provider = described_class.new(transport: transport_embed(embed_body([0.1, 0.2])))

      expect { provider.embed(%w[a b]) }.to raise_error(Lain::Embedder::Ollama::APIError)
    end

    it "raises when a vector is not a list of numbers" do
      provider = described_class.new(transport: transport_embed(embed_body(%w[not a vector])))

      expect { provider.embed(%w[a]) }.to raise_error(Lain::Embedder::Ollama::APIError)
    end

    # Probe finding: [[0.1], [0.2, 0.3]] for two inputs came back silently ragged.
    # Equal dimension across the batch is part of the vector contract -- a ragged
    # batch would poison any distance computed downstream, so it is a torn body.
    it "raises when vector dimensions differ across the batch, rather than returning ragged vectors" do
      provider = described_class.new(transport: transport_embed(embed_body([0.1], [0.2, 0.3])))

      expect { provider.embed(%w[a b]) }.to raise_error(Lain::Embedder::Ollama::APIError, /dimension/)
    end

    it "raises Embedder::Error (the family root), not a bare Lain::Error, so callers rescue one family" do
      provider = described_class.new(transport: transport_embed({}))

      expect { provider.embed(%w[a]) }.to raise_error(Lain::Embedder::Error)
    end
  end

  # Panel finding: the embed transport had copy-pasted Provider::Ollama's
  # base-url posture (api_base/DEFAULT_API_BASE, configuration_options, local?,
  # header merge) instead of reusing it. Pin the reuse structurally: the embed
  # transport IS Provider::Ollama's transport surface, differing only in path.
  describe "Transport" do
    it "reuses Provider::Ollama's transport rather than duplicating its base-url posture" do
      expect(described_class::Transport.ancestors).to include(Lain::Provider::Ollama::Transport)
    end

    it "inherits the local, keyless posture" do
      expect(described_class::Transport.local?).to be(true)
      expect(described_class::Transport.configuration_requirements).to be_empty
    end
  end

  # The real Faraday transport, exercised once end-to-end over WebMock so the URL,
  # path, JSON serialization, and error mapping are pinned -- not just the double.
  describe "over the real transport", :webmock do
    it "posts the batch to /api/embed at the default base and returns the vectors" do
      stub = stub_request(:post, "http://localhost:11434/api/embed")
             .with { |req| JSON.parse(req.body).values_at("model", "input") == ["nomic-embed-text", %w[a b]] }
             .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                        body: JSON.generate(embed_body([0.1, 0.2, 0.3], [0.4, 0.5, 0.6])))

      vectors = described_class.new.embed(%w[a b])

      expect(vectors).to eq([[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]])
      expect(stub).to have_been_requested
    end

    # AC: a non-2xx body is loud -- wrapped into APIStatusError with the status
    # lifted out, so nothing above the Embedder rescues a Provider::HTTP class.
    it "wraps a 404 (model not pulled) into APIStatusError with the status lifted out" do
      stub_request(:post, "http://localhost:11434/api/embed")
        .to_return(status: 404, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("error" => "model \"nomic-embed-text\" not found, try pulling it first"))

      expect { described_class.new.embed(%w[a]) }.to raise_error(
        Lain::Embedder::Ollama::APIStatusError
      ) { |error| expect(error.status).to eq(404) }
    end

    it "wraps a 500 into APIStatusError with the status lifted out" do
      stub_request(:post, "http://localhost:11434/api/embed")
        .to_return(status: 500, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("error" => "server error"))

      expect { described_class.new.embed(%w[a]) }.to raise_error(
        Lain::Embedder::Ollama::APIStatusError
      ) { |error| expect(error.status).to eq(500) }
    end
  end

  # AC: live round trip. Hits a REAL local Ollama with the pinned embed model.
  #
  # Tagged :ollama (orchestrator ruling): the purpose-built keyless local gate --
  # LAIN_OLLAMA=1, server reachability + skip-not-fail already owned by
  # spec/support/ollama_tag.rb. One residual in-spec guard survives the switch:
  # the tag's model probe pins the CHAT model (qwen3:4b), so the EMBED model's
  # presence still has to be checked here (skip, never fail, when unpulled).
  #
  #   LAIN_OLLAMA=1 bundle exec rspec spec/lain/embedder/ollama_spec.rb
  describe "a live /api/embed round trip", :ollama do
    let(:model) { described_class::DEFAULT_MODEL }

    # The tag's before-hook has already skipped on an unreachable server, so a
    # nil tags fetch cannot happen here -- only the embed model can be missing.
    # Ollama stores a tagless reference under its ":latest" tag, so match the
    # exact name and any "model:tag" form (the wire separator is ":").
    before do
      names = Array(OllamaTestServer.fetch_tags(OLLAMA_API_BASE)&.[]("models")).filter_map { |entry| entry["name"] }
      present = names.any? { |name| name == model || name.start_with?("#{model}:") }
      skip "Ollama embed model #{model.inspect} not pulled -- run `ollama pull #{model}`" unless present
    end

    it "returns one vector per text at the model's advertised dimension" do
      vectors = described_class.new(api_base: OLLAMA_API_BASE).embed(%w[kidney liver])

      expect(vectors.size).to eq(2)
      expect(vectors.map(&:size).uniq.size).to eq(1)
      expect(vectors.first.size).to be > 0
      expect(vectors.first).to all(be_a(Float))
    end
  end

  # A transport double that captures the payload it was handed.
  def capturing_transport
    Class.new do
      attr_reader :payload

      def embed_post(payload)
        @payload = payload
        Struct.new(:body).new({ "embeddings" => Array.new(payload[:input].size) { [0.0, 0.0] } })
      end
    end.new
  end
end
