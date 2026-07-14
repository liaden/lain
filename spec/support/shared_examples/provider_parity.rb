# frozen_string_literal: true

# The seven correctness gates from spec/lain/agent_spec.rb, plus the Provider
# contract from lib/lain/provider.rb (see spec/lain/provider_spec.rb), reframed
# as ONE shared example group every Lain::Provider must satisfy. Without this,
# a new backend can land half-working: it could pass its own unit specs while
# quietly dropping a thinking block, splitting tool_results across two user
# turns, or swallowing an unrecognized stop_reason -- exactly the failure
# modes the plan calls "gate 1" through "gate 7".
#
# Include with a Hash:
#
#   provider_factory [#call(Array<Lain::Response>) -> Lain::Provider]
#     Given a canned sequence of Responses, returns a Provider that yields
#     them in order when driven through a real Lain::Agent loop.
#     Lain::Provider::Mock satisfies this directly:
#       ->(responses) { Lain::Provider::Mock.new(responses: responses) }
#     A live/cassette-backed provider (Provider::AnthropicRaw, landing on the
#     `transport` branch) needs a cassette recorded to reproduce the same
#     Response sequence -- this group deliberately does NOT run against
#     Provider::Anthropic yet, but any provider handed through
#     provider_factory slots in unchanged. The seam is here, waiting.
#
# Example:
#   RSpec.describe Lain::Provider::Mock do
#     include_examples "a Lain::Provider",
#       provider_factory: ->(responses) { described_class.new(responses: responses) }
#   end
RSpec.shared_examples "a Lain::Provider" do |config|
  provider_factory = config.fetch(:provider_factory)

  # ---- fixtures, over spec/support/mock_recording.rb ------------------------
  #
  # The parity_ prefix keeps this group's fixture names clear of anything an
  # including spec defines for itself.

  let(:parity_toolset) { Lain::Toolset.new([EchoTool.new, BoomTool.new]) }
  let(:parity_context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }

  def parity_text_response(text = "done", stop_reason: :end_turn)
    text_response(text, stop_reason:)
  end

  def parity_tool_response(*calls)
    tool_response(*calls, thinking: "considering")
  end

  define_method(:parity_agent) do |provider_factory, responses, toolset: nil, **overrides|
    Lain::Agent.new(
      provider: provider_factory.call(Array(responses)),
      toolset: toolset || parity_toolset,
      context: parity_context,
      **overrides
    )
  end

  # ---- the Provider contract itself -----------------------------------------

  describe "the Provider contract" do
    subject(:provider) { provider_factory.call([]) }

    let(:sample_request) do
      Lain::Request.new(
        model: "m", max_tokens: 8, system: "be terse",
        tools: [{ name: "t", description: "d", input_schema: { type: :object, properties: {}, required: [] } }],
        messages: [{ "role" => "user", "content" => [{ "type" => "text", "text" => "hi" }] }]
      )
    end

    it "declares capabilities that are a subset of Provider::CAPABILITIES" do
      expect(Lain::Provider::CAPABILITIES).to include(*provider.capabilities)
    end

    # This is the prompt-cache-stability invariant, not a style preference:
    # Anthropic's cache is a prefix match over the encoded bytes, so any
    # nondeterminism in #encode (Hash key order, an unstable sort) reads on
    # the wire as a different prompt every single call.
    it "encodes deterministically -- the same Request twice yields identical bytes" do
      first = provider.encode(sample_request)
      second = provider.encode(sample_request)
      expect(Lain::Canonical.dump(first)).to eq(Lain::Canonical.dump(second))
    end

    it "supports? and require! answer consistently with the declared capabilities" do
      provider.capabilities.each do |capability|
        expect(provider.supports?(capability)).to be(true)
        expect(provider.require!(capability)).to be(true)
      end

      (Lain::Provider::CAPABILITIES - provider.capabilities).each do |capability|
        expect(provider.supports?(capability)).to be(false)
        expect { provider.require!(capability) }.to raise_error(Lain::Provider::Unsupported)
      end
    end

    it "#complete returns a Lain::Response retaining every content block" do
      blocks = [{ "type" => "thinking", "thinking" => "..." },
                { "type" => "tool_use", "id" => "tu_1", "name" => "t", "input" => {} }]
      scripted = provider_factory.call([Lain::Response.new(content: blocks, stop_reason: :tool_use)])

      response = scripted.complete(sample_request)

      expect(response).to be_a(Lain::Response)
      expect(response.content.map { |block| block["type"] }).to eq(%w[thinking tool_use])
    end
  end

  # ---- the seven correctness gates, driven through a real Agent -----------

  describe "gate 1: the FULL response content is appended" do
    it "retains thinking and tool_use blocks on the assistant turn" do
      a = parity_agent(provider_factory,
                       [parity_tool_response(["tu_1", "echo", { "text" => "x" }]), parity_text_response])
      a.ask("hi")

      assistant = a.timeline.to_a.find { |turn| turn.role == "assistant" }
      expect(assistant.content.map { |block| block["type"] }).to eq(%w[thinking tool_use])
    end
  end

  describe "gate 2: all tool_results return in ONE user message" do
    it "appends a single user turn holding every result" do
      a = parity_agent(provider_factory,
                       [parity_tool_response(["tu_1", "echo", { "text" => "a" }],
                                             ["tu_2", "echo", { "text" => "b" }]),
                        parity_text_response])
      a.ask("hi")

      results_turn = a.timeline.to_a[2]
      expect(results_turn.role).to eq("user")
      expect(results_turn.content.map { |block| block["type"] }).to eq(%w[tool_result tool_result])
    end
  end

  describe "gate 3: a raising tool becomes an error result, and the loop continues" do
    it "reports is_error and keeps going" do
      a = parity_agent(provider_factory,
                       [parity_tool_response(["tu_1", "boom", {}]), parity_text_response("recovered")])
      response = a.ask("hi")

      result_block = a.timeline.to_a[2].content.first
      expect(result_block["is_error"]).to be(true)
      expect(response.text).to eq("recovered")
      expect(a).to be_done
    end
  end

  describe "gate 4: every tool_result carries its matching tool_use_id" do
    it "pairs ids one for one" do
      a = parity_agent(provider_factory,
                       [parity_tool_response(["tu_1", "echo", { "text" => "a" }],
                                             ["tu_2", "echo", { "text" => "b" }]),
                        parity_text_response])
      a.ask("hi")

      ids = a.timeline.to_a[2].content.map { |block| block["tool_use_id"] }
      expect(ids).to eq(%w[tu_1 tu_2])
    end
  end

  describe "gate 5: tool input reaches the tool as a parsed object" do
    it "hands the tool a Hash, never a JSON string" do
      seen = nil
      capturing = Class.new(Lain::Tool) do
        define_method(:name) { "capture" }
        define_method(:description) { "captures" }
        define_method(:input_schema) { { type: :object, properties: {} } }
        define_method(:perform) do |input, _context|
          seen = input
          Lain::Tool::Result.ok("ok")
        end
      end

      a = parity_agent(provider_factory,
                       [parity_tool_response(["tu_1", "capture", { "path" => "a.rb" }]), parity_text_response],
                       toolset: Lain::Toolset.new([capturing.new]))
      a.ask("hi")

      expect(seen).to be_a(Hash)
      expect(seen).to eq({ "path" => "a.rb" })
    end
  end

  describe "gate 6: stop_reason handling is total" do
    it "settles done on end_turn" do
      a = parity_agent(provider_factory, parity_text_response)
      a.ask("hi")
      expect(a).to be_done
    end

    # Easy to forget, and it really does occur.
    it "settles done on stop_sequence" do
      a = parity_agent(provider_factory, parity_text_response("x", stop_reason: :stop_sequence))
      a.ask("hi")
      expect(a).to be_done
    end

    it "fails on refusal" do
      a = parity_agent(provider_factory, parity_text_response("", stop_reason: :refusal))
      a.ask("hi")
      expect(a).to be_failed
    end

    it "fails on max_tokens" do
      a = parity_agent(provider_factory, parity_text_response("", stop_reason: :max_tokens))
      a.ask("hi")
      expect(a).to be_failed
    end

    # The wire enums are non-exhaustive. An unrecognized value must fail
    # loudly, not fall through a `case` and quietly do nothing.
    it "fails on an unrecognized stop_reason rather than falling through silently" do
      a = parity_agent(provider_factory, Lain::Response.new(content: [], stop_reason: "something_new_in_2027"))
      a.ask("hi")
      expect(a).to be_failed
    end

    # A server-side tool is mid-flight; resend and let it continue rather than
    # settling.
    it "re-requests on pause_turn rather than settling" do
      a = parity_agent(provider_factory,
                       [parity_text_response("", stop_reason: :pause_turn), parity_text_response("finished")])
      response = a.ask("hi")

      expect(response.text).to eq("finished")
      expect(a).to be_done
    end
  end

  describe "gate 7: the loop is bounded" do
    it "raises once max_iterations is reached" do
      a = parity_agent(provider_factory,
                       [parity_tool_response(["tu_1", "echo", { "text" => "loop" }])],
                       budget: Lain::Agent::Budget.new(max_iterations: 3))
      expect { a.ask("hi") }.to raise_error(Lain::Agent::BudgetExceeded, /3 iterations/)
    end
  end
end
