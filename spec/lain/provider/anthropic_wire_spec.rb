# frozen_string_literal: true

RSpec.describe Lain::Provider::AnthropicWire do
  # A bare includer: the module is the whole subject, so nothing here needs a
  # transport, a config, or a network. `wire_payload` is the only method that
  # reaches outside the module -- it calls #encode -- so the double supplies it.
  let(:includer) do
    Class.new do
      include Lain::Provider::AnthropicWire

      def initialize(encoded = {})
        @encoded = encoded
      end

      def encode(_request) = @encoded.dup

      # The module's methods are private in every real includer; these are the
      # doors the examples drive them through.
      def wire(request) = wire_payload(request)
      def respond(assembled) = build_response(assembled)
      def backoff(config) = apply_rate_limit_backoff(config)
    end
  end

  let(:request) { Struct.new(:stream, :digest).new(true, "d1") }

  def assembled(content:, usage: {}, id: "msg_1", model: "claude-opus-4-8", stop_reason: "end_turn")
    Lain::Provider::Anthropic::StreamAssembler::Assembled.new(id:, model:, stop_reason:, content:, usage:)
  end

  describe "both hosted backends include it" do
    it "is in Provider::Anthropic's ancestry" do
      expect(Lain::Provider::Anthropic.ancestors).to include(described_class)
    end

    it "is in Provider::Bedrock's ancestry" do
      expect(Lain::Provider::Bedrock.ancestors).to include(described_class)
    end

    # Both classes read the constants unqualified from their own bodies, and
    # both specs' `described_class::RATE_LIMIT_RESET_HEADER` must keep
    # resolving -- constant lookup walks ancestors, so the move is invisible.
    it "keeps the reset header resolvable through each includer" do
      expect(Lain::Provider::Anthropic::RATE_LIMIT_RESET_HEADER).to eq(described_class::RATE_LIMIT_RESET_HEADER)
      expect(Lain::Provider::Bedrock::RATE_LIMIT_RESET_HEADER).to eq(described_class::RATE_LIMIT_RESET_HEADER)
    end

    # The card's escalation trigger, pinned as a spec: the two copies of this
    # open question ("which rate-limit header governs backoff") agreed on
    # `anthropic-ratelimit-tokens-reset`, and the collapse must not quietly
    # pick a side. One constant now, so they cannot drift apart again.
    it "governs backoff by the tokens reset, the header both copies already named" do
      expect(described_class::RATE_LIMIT_RESET_HEADER).to eq("anthropic-ratelimit-tokens-reset")
    end
  end

  # faraday-retry's own parser understands seconds or an RFC2822 date; Anthropic
  # sends RFC3339 resets AND a plain-seconds `retry-after`, so one lambda has to
  # answer both. Neither hand-written copy had a spec on it.
  describe "RESET_HEADER_PARSER" do
    let(:parse) { described_class::RESET_HEADER_PARSER }

    it "reads a bare integer as seconds" do
      expect(parse.call("2")).to eq(2.0)
    end

    it "reads a bare decimal as seconds" do
      expect(parse.call("1.5")).to eq(1.5)
    end

    it "turns an RFC3339 timestamp into seconds from now" do
      expect(parse.call((Time.now + 30).iso8601)).to be_within(2.0).of(30.0)
    end

    # A reset already in the past must never become a negative sleep.
    it "floors a past timestamp at zero rather than going negative" do
      expect(parse.call((Time.now - 60).iso8601)).to eq(0.0)
    end

    it "is nil for an absent header, so faraday-retry falls back to its schedule" do
      expect(parse.call(nil)).to be_nil
      expect(parse.call("")).to be_nil
    end

    it "is nil for an unparseable value rather than raising inside the retry loop" do
      expect(parse.call("whenever")).to be_nil
    end
  end

  describe "#apply_rate_limit_backoff" do
    it "sets both the header name and the parser on the config" do
      config = includer.new.backoff(Lain::Provider::HTTP::Configuration.new)

      expect(config.rate_limit_reset_header).to eq(described_class::RATE_LIMIT_RESET_HEADER)
      expect(config.header_parser_block).to eq(described_class::RESET_HEADER_PARSER)
    end
  end

  describe "#wire_payload" do
    it "rewrites the system_ kwarg to the wire's system and adds the stream flag" do
      payload = includer.new({ model: "m", system_: "be terse" }).wire(request)

      expect(payload).not_to have_key(:system_)
      expect(payload[:system]).to eq("be terse")
      expect(payload[:stream]).to be(true)
    end

    it "leaves a system-less payload without a system key" do
      payload = includer.new({ model: "m" }).wire(request)

      expect(payload).not_to have_key(:system)
      expect(payload[:stream]).to be(true)
    end
  end

  describe "#build_response" do
    it "retains every block in order, thinking signatures included" do
      blocks = [{ "type" => "thinking", "thinking" => "...", "signature" => "sig" },
                { "type" => "text", "text" => "hi" }]

      response = includer.new.respond(assembled(content: blocks))

      expect(response.content).to eq(blocks)
      expect(response.id).to eq("msg_1")
      expect(response.stop_reason).to eq(:end_turn)
    end

    # Belt-and-suspenders on Response#tool_uses: a String input must never
    # reach the Timeline. Both hand-written copies carried this; the shared one
    # keeps it.
    it "parses a tool_use input that arrived as a JSON String" do
      blocks = [{ "type" => "tool_use", "id" => "tu_1", "name" => "t", "input" => '{"path":"a.rb"}' }]

      response = includer.new.respond(assembled(content: blocks))

      expect(response.content.first["input"]).to eq({ "path" => "a.rb" })
    end

    it "leaves an already-parsed tool_use input untouched" do
      blocks = [{ "type" => "tool_use", "id" => "tu_1", "name" => "t", "input" => { "path" => "a.rb" } }]

      expect(includer.new.respond(assembled(content: blocks)).content).to eq(blocks)
    end

    it "decodes usage through the one Anthropic-wire decoder" do
      wire = { "input_tokens" => 7, "output_tokens" => 3, "cache_read_input_tokens" => 11 }

      response = includer.new.respond(assembled(content: [], usage: wire))

      expect(response.usage).to eq(Lain::Usage.from_anthropic_wire(wire))
      expect(response.usage.cache_read_input_tokens).to eq(11)
    end
  end
end
