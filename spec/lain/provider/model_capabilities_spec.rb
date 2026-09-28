# frozen_string_literal: true

require "json"
require "webmock/rspec"

RSpec.describe Lain::Provider::ModelCapabilities do
  let(:support) { described_class::Support }

  def transport_show(body, &counter)
    Class.new do
      define_method(:model_details) do |model|
        counter&.call(model)
        Struct.new(:body).new(body)
      end
    end.new
  end

  def show_body(*capabilities)
    { "model_info" => { "general.architecture" => "qwen3" }, "capabilities" => capabilities }
  end

  def local(transport) = Lain::Provider::Ollama.new(transport:)

  describe "a model's vision support, answered by the server" do
    it "reports vision as supported, and says the server is where that came from" do
      probed = local(transport_show(show_body("completion", "tools", "vision"))).model_capabilities("ornith-1.5:9b")

      expect([probed.supports?(:vision), probed.provenance])
        .to eq([support::SUPPORTED, described_class::PROBED])
    end

    # The whole point of the third answer: a model the server DESCRIBED, whose
    # description omits vision, is a model that has not got it. That is a no,
    # and it has to be distinguishable from never having asked.
    it "reports vision as unsupported for a described model whose description omits it" do
      probed = local(transport_show(show_body("completion", "tools"))).model_capabilities("gemma4:e4b")

      expect([probed.supports?(:vision), probed.provenance])
        .to eq([support::UNSUPPORTED, described_class::PROBED])
    end
  end

  describe "a server that cannot answer" do
    it "answers unknown rather than asserting absence when /api/show fails", :webmock do
      stub_request(:post, "http://localhost:11434/api/show").to_raise(Faraday::ConnectionFailed)

      unanswered = Lain::Provider::Ollama.new.model_capabilities("qwen3:4b")

      expect([unanswered.supports?(:vision), unanswered.provenance])
        .to eq([support::UNKNOWN, described_class::UNKNOWN])
    end

    it "answers unknown for a 404 on a model the server has not got", :webmock do
      stub_request(:post, "http://localhost:11434/api/show")
        .to_return(status: 404, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("error" => "model not found"))

      expect(Lain::Provider::Ollama.new.model_capabilities("nosuch:1b").provenance).to eq(described_class::UNKNOWN)
    end

    [{ "model_info" => { "general.architecture" => "qwen3" } },
     { "capabilities" => nil },
     { "capabilities" => "tools" },
     "not a description at all"].each do |body|
      it "answers unknown rather than empty for #{body.inspect}" do
        answer = local(transport_show(body)).model_capabilities("qwen3:4b")

        expect([answer.provenance, answer.supports?(:tools)])
          .to eq([described_class::UNKNOWN, support::UNKNOWN])
      end
    end

    # The one input that IS a blanket no, and the reason it is not in the table
    # above: the server described the model and listed nothing, which is an
    # answer. Kept separate so a reader can see the branch was considered.
    it "keeps an empty array as a probed answer, which is the only blanket no" do
      answer = local(transport_show("capabilities" => [])).model_capabilities("embed-only:1b")

      expect([answer.provenance, answer.supports?(:tools)])
        .to eq([described_class::PROBED, support::UNSUPPORTED])
    end
  end

  # An arm whose metadata endpoint is unverified declines to probe -- the same
  # reason `Deployment#model_metadata?` already gates `#trained_context_tokens`.
  # A cloud model that really does have vision reads UNKNOWN here, which is why
  # unknown is a third answer rather than a no.
  describe "the cloud arm" do
    it "makes no /api/show request, and answers unknown" do
      refusing = Class.new do
        define_method(:model_details) { |_model| raise "the cloud arm must not ask /api/show" }
      end.new
      cloud = Lain::Provider::Ollama.cloud(api_key: "sk-test", transport: refusing)

      answer = cloud.model_capabilities("glm-5.3-flash:cloud")

      expect([answer.provenance, answer.supports?(:vision)]).to eq([described_class::UNKNOWN, support::UNKNOWN])
    end
  end

  # The measurement this reader exists for: `thinking` was a provider-wide
  # claim, and the probes disprove it per model.
  describe "thinking, asked per model" do
    it "answers differently for two models on one server, rather than inheriting one claim" do
      thinker = local(transport_show(show_body("completion", "tools", "thinking")))
      plain = local(transport_show(show_body("completion")))

      expect([thinker.model_capabilities("qwen3:4b").supports?(:thinking),
              plain.model_capabilities("gemma4:e4b").supports?(:thinking)])
        .to eq([support::SUPPORTED, support::UNSUPPORTED])
    end

    it "is no longer a provider-wide capability, so there is one source for the fact" do
      expect(Lain::Provider::Ollama::CAPABILITIES).not_to include(:thinking)
    end
  end

  # A probe per turn is what `#context_window_tokens` deliberately pays for a
  # SERVED window, which changes when a runner reloads. A model file's
  # capabilities do not, so this one is bought once per model and kept.
  describe "what it costs to ask" do
    it "asks the server once per model however often it is read" do
      asked = []
      provider = local(transport_show(show_body("completion", "vision")) { |model| asked << model })

      3.times { provider.model_capabilities("ornith-1.5:9b") }
      provider.model_capabilities("gemma4:e4b")

      expect(asked).to eq(%w[ornith-1.5:9b gemma4:e4b])
    end

    it "keeps a failed probe's answer too, rather than spending the timeout again", :webmock do
      stub_request(:post, "http://localhost:11434/api/show").to_raise(Faraday::ConnectionFailed)
      provider = Lain::Provider::Ollama.new

      2.times { provider.model_capabilities("qwen3:4b") }

      expect(a_request(:post, "http://localhost:11434/api/show")).to have_been_made.once
    end

    # The memo is that provider's run state, not a process-wide cache -- which
    # is what a reader wondering how to clear a stale UNKNOWN needs to know.
    it "is the provider instance's own memo, so a fresh provider probes again" do
      asked = []
      transport = transport_show(show_body("vision")) { |model| asked << model }

      2.times { local(transport).model_capabilities("ornith-1.5:9b") }

      expect(asked).to eq(%w[ornith-1.5:9b ornith-1.5:9b])
    end
  end

  describe "the value itself" do
    it "is deeply frozen, like every other value on the render path" do
      expect(described_class.of(show_body("completion", "vision"))).to be_deeply_frozen
    end

    # `.probed` guarded its own argument; `.new` and `Data#with` did not, so an
    # Array a caller still held reached a frozen value and Ractor refused it.
    it "settles what the PUBLIC constructor was handed, not only what a factory built" do
      handed = ["tools"]
      reading = described_class.new(names: handed, provenance: described_class::PROBED)

      expect([Ractor.shareable?(reading), reading.names.frozen?, handed.frozen?]).to eq([true, true, false])
    end

    # A bare String passed where an Array goes made `#supports?` call
    # `String#include?`, so every substring of a capability name answered
    # SUPPORTED.
    it "cannot be talked into a substring match by a bare String" do
      reading = described_class.new(names: "tools", provenance: described_class::PROBED)

      expect([reading.supports?(:too), reading.supports?(:tools)])
        .to eq([support::UNSUPPORTED, support::SUPPORTED])
    end

    it "refuses a provenance outside the two it defines" do
      expect { described_class.new(names: [], provenance: :guessed) }
        .to raise_error(ArgumentError, /must be one of/)
    end

    # Value equality, so a caller holding two readings can compare them and a
    # spec can assert on the whole answer rather than on a predicate at a time.
    it "equals another reading of the same answer" do
      expect(described_class.of(show_body("tools"))).to eq(described_class.of(show_body("tools")))
    end

    it "drops a non-String entry rather than letting it reach a comparison" do
      expect(described_class.of("capabilities" => ["tools", 4, nil]).supports?(:tools)).to eq(support::SUPPORTED)
    end

    # Asking about nothing is not a refusal. `nil.to_s` matched no name and read
    # as UNSUPPORTED, which is the one answer a missing question may not give.
    it "answers unknown for a nil capability rather than reading it as a no" do
      expect(described_class.of(show_body("tools")).supports?(nil)).to eq(support::UNKNOWN)
    end
  end

  describe "how a caller branches on an answer" do
    # The policy is the CONSUMER's, and naming three arms is what puts it where
    # a reader of the call site can see it. A predicate pair leaves the unknown
    # arm falling wherever a boolean sends it.
    it "makes a caller name all three arms" do
      offered = [support::SUPPORTED, support::UNSUPPORTED, support::UNKNOWN]
                .map { |answer| answer.either(supported: :offer, unsupported: :withhold, unknown: :offer) }

      expect(offered).to eq(%i[offer withhold offer])
    end

    it "lets a consumer with the opposite policy say so in the same breath" do
      expect(support::UNKNOWN.either(supported: :offer, unsupported: :withhold, unknown: :withhold))
        .to eq(:withhold)
    end

    # Three values and never a fourth: `Support.new(answer: :banana)` answered
    # every branch falsely and destructured cleanly.
    it "offers no fourth answer to construct" do
      expect { support.new(answer: :banana) }.to raise_error(NoMethodError, /private method/)
    end

    # Closed so `#either` is the only branch -- `answer == :supported` at a call
    # site is exactly the reading three named arms exist to prevent.
    it "does not expose the raw answer for a call site to compare against" do
      expect { support::SUPPORTED.answer }.to raise_error(NoMethodError, /private method/)
    end
  end
end
