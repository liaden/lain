# frozen_string_literal: true

require "json"

RSpec.describe Lain::Gateway::Upstream do
  let(:ollama) { described_class.for("https://ollama.com") }
  let(:body) { JSON.generate({ model: "glm-5.3:cloud", stream: false, messages: [] }) }

  def answering(url, **response)
    stub_request(:post, url).to_return({ status: 200, body: "{}", headers: { "Content-Type" => "application/json" } }
                                         .merge(response))
  end

  def sent_headers(stub)
    seen = nil
    stub.with { |request| seen = request.headers.keys.sort }
    yield
    seen
  end

  describe ".for" do
    it "refuses a host outside the allow-list, naming the allowed hosts" do
      expect { described_class.for("https://example.com") }
        .to raise_error(described_class::NotAllowed, /ollama\.com.*api\.anthropic\.com/)
    end

    it "refuses a plaintext upstream, naming https" do
      expect { described_class.for("http://ollama.com") }
        .to raise_error(described_class::NotAllowed, /only over https/)
    end

    it "takes the allowed base with a trailing slash" do
      expect(described_class.for("https://ollama.com/").base).to eq("https://ollama.com")
    end

    {
      "another port" => "https://ollama.com:8443",
      "userinfo" => "https://user@ollama.com",
      "a path" => "https://ollama.com/api",
      "a query" => "https://ollama.com?x=1",
      "a trailing dot" => "https://ollama.com.",
      "another case" => "https://OLLAMA.COM"
    }.each do |shape, url|
      it "refuses an allowed host spelled with #{shape}" do
        expect { described_class.for(url) }.to raise_error(described_class::NotAllowed)
      end
    end
  end

  describe "construction outside .for" do
    it "refuses a base outside the allow-list through new" do
      expect { described_class.new(base: "https://evil.example", auth_header: "Authorization", key_env: "OLLAMA_API_KEY") }
        .to raise_error(described_class::NotAllowed)
    end

    it "refuses a base outside the allow-list through with" do
      expect { ollama.with(base: "https://localhost:8443") }.to raise_error(described_class::NotAllowed)
    end

    it "refuses an allowed base paired with another variable's key" do
      expect { ollama.with(key_env: "HOME") }.to raise_error(described_class::NotAllowed)
    end
  end

  describe "#forward" do
    around do |example|
      with_env("OLLAMA_API_KEY" => "gateway-key", "ANTHROPIC_API_KEY" => "anthropic-key") { example.run }
    end

    it "posts the same body with exactly the gateway's own headers" do
      stub = answering("https://ollama.com/api/chat")

      headers = sent_headers(stub) { expect(ollama.forward("/api/chat", body).code).to eq("200") }

      expect(a_request(:post, "https://ollama.com/api/chat")
               .with(body:, headers: { "Authorization" => "Bearer gateway-key" })).to have_been_made.once
      expect(headers).to eq(%w[Accept Accept-Encoding Authorization Content-Type User-Agent])
    end

    it "sends the anthropic key as x-api-key with a version, and no Authorization" do
      stub = answering("https://api.anthropic.com/v1/messages")
      anthropic = described_class.for("https://api.anthropic.com")

      headers = sent_headers(stub) { anthropic.forward("/v1/messages", body) }

      expect(a_request(:post, "https://api.anthropic.com/v1/messages")
               .with(headers: { "X-Api-Key" => "anthropic-key", "Anthropic-Version" => "2023-06-01" }))
        .to have_been_made.once
      expect(headers).not_to include("Authorization")
    end

    it "refuses a path outside the upstream's allow-list before connecting" do
      answering(%r{\Ahttps://ollama\.com/})

      expect { ollama.forward("/api/pull", body) }.to raise_error(described_class::NotAllowed, %r{/api/chat})
      expect(a_request(:any, /ollama/)).not_to have_been_made
    end

    it "connects directly even when the environment names a proxy" do
      answering("https://ollama.com/api/chat")
      proxied = []
      allow(Net::HTTP).to receive(:start).and_wrap_original do |original, *args, **opts, &block|
        original.call(*args, **opts) do |http|
          proxied << http.proxy?
          block.call(http)
        end
      end

      with_env("http_proxy" => "http://127.0.0.1:9", "https_proxy" => "http://127.0.0.1:9") { ollama.forward("/api/chat", body) }

      expect(proxied).to eq([false])
    end

    it "masks the gateway's key where the upstream echoes it back" do
      answering("https://ollama.com/api/chat", status: 401, body: %({"error":"bad key Bearer gateway-key"}))

      expect(ollama.forward("/api/chat", body).body).not_to include("gateway-key")
    end

    it "gives a masked answer the length of its masked body" do
      echoed = %({"error":"bad key Bearer gateway-key"})
      answering("https://ollama.com/api/chat", status: 401, body: echoed,
                                               headers: { "Content-Length" => echoed.bytesize.to_s })

      response = ollama.forward("/api/chat", body)

      expect(response["content-length"]).to eq(response.body.bytesize.to_s)
    end

    it "masks a key that is not ASCII in an answer that is not ASCII" do
      answering("https://ollama.com/api/chat", status: 401, body: "clé refusée: Bearer gäteway-key".b)

      with_env("OLLAMA_API_KEY" => "gäteway-key") do
        expect(ollama.forward("/api/chat", body).body).not_to include("gäteway-key".b)
      end
    end

    it "refuses a response larger than the cap" do
      stub_const("#{described_class}::MAX_RESPONSE_BYTES", 16)
      answering("https://ollama.com/api/chat", body: "x" * 17)

      expect { ollama.forward("/api/chat", body) }.to raise_error(described_class::ForwardFailed, /over 16 bytes/)
    end

    it "stops a forward that runs past its overall deadline" do
      stub_const("#{described_class}::DEADLINE", 0.2)
      stub_request(:post, "https://ollama.com/api/chat").to_return do
        sleep 2
        { status: 200, body: "{}" }
      end

      expect { ollama.forward("/api/chat", body) }.to raise_error(described_class::ForwardFailed, /ollama\.com/)
    end

    {
      "a refused connection" => Errno::ECONNREFUSED,
      "a TLS failure" => OpenSSL::SSL::SSLError.new("verify failed for Bearer gateway-key"),
      "a timeout" => Net::OpenTimeout,
      "a compressed answer that does not decompress" => Zlib::DataError.new("incorrect header check")
    }.each do |failure, error|
      it "names the host and never the key on #{failure}" do
        stub_request(:post, "https://ollama.com/api/chat").to_raise(error)

        expect { ollama.forward("/api/chat", body) }.to raise_error(described_class::ForwardFailed) do |raised|
          expect(raised.message).to include("ollama.com")
          expect(raised.message).not_to include("gateway-key")
        end
      end
    end

    { "a tab" => "gateway\tkey", "a carriage return" => "gateway-key\r" }.each do |shape, key|
      it "refuses a key holding #{shape}, never quoting it" do
        with_env("OLLAMA_API_KEY" => key) do
          expect { ollama.forward("/api/chat", body) }.to raise_error(described_class::MissingKey) do |raised|
            expect(raised.message).not_to include(key)
          end
        end
      end
    end

    it "refuses to forward when the gateway's own environment holds no key" do
      with_env("OLLAMA_API_KEY" => nil) do
        expect { ollama.forward("/api/chat", body) }.to raise_error(described_class::MissingKey, /OLLAMA_API_KEY/)
      end
    end
  end
end
