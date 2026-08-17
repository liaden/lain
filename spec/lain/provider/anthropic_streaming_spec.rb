# frozen_string_literal: true

# T11 / F7c. The SSE streaming path, driven over a REAL socket that dies
# mid-body, because that is the only instrument that can express this defect.
#
# `Provider::Anthropic#stream_dispatch` builds ONE {StreamAssembler} per round
# trip and faraday-retry replays the attempt through the SAME block, so an
# abandoned attempt's blocks are still sitting in that assembler when the
# replacement starts feeding it. `on_block_start` replaces `@blocks[index]`,
# which hides the damage for a retry that reopens every index the abandoned
# attempt opened -- and hides nothing at all for one that opens FEWER. The
# surviving block rides into the response with a clean `stop_reason` and clean
# usage, and when the abandoned attempt had reached a `tool_use` it is a phantom
# tool call in the assistant message.
#
# WebMock cannot stage this: it hands a stubbed body back as one chunk and a
# connection severed mid-body raises inside its own read, so the bytes that DID
# arrive never reach the caller. Hence {StreamingUpstream}, and hence the
# assertions counting `upstream.requests` rather than `have_been_made` -- a
# bypassed request is invisible to WebMock by design.
#
# Untagged with `:vcr`, and deliberately: a replaying cassette makes
# `NetworkAccess.permit_loopback` inert and the refusal names neither cause.
RSpec.describe Lain::Provider::Anthropic, "streaming across a retry", :seam do
  let(:wire) { StreamingUpstream::Wire }

  # The abandoned attempt: a text block it closed, and a tool_use block it had
  # opened and begun filling when the connection died.
  let(:rich) do
    Lain::Response.new(content: [{ "type" => "text", "text" => "partial prose" },
                                 { "type" => "tool_use", "id" => "toolu_orphan",
                                   "name" => "echo", "input" => { "text" => "hi" } }],
                       stop_reason: :tool_use)
  end

  # The retry: ONE block, so index 1 is never reopened and nothing overwrites it.
  let(:lean) { Lain::Response.new(content: [{ "type" => "text", "text" => "the retry" }], stop_reason: :end_turn) }

  # Frames are start/delta/stop PER BLOCK, so the prefix that leaves the SECOND
  # block OPEN is SIX frames: message_start, block 0's three, then block 1's
  # start and delta. Four would serve a fully closed block 0 and open no orphan
  # at all -- an example built on that asserts nothing and passes. The exact
  # sequence is pinned by a committed example in
  # spec/lain/seams/streaming_upstream_spec.rb ("can serve a prefix that leaves
  # the second block open"), so a drift in AnthropicSSE's framing turns this
  # file's premise red rather than quiet.
  def severed_prefix(response, frames:) = StreamingUpstream.script.chunks(*wire.sse_frames(response).take(frames)).sever

  def whole(response) = StreamingUpstream.script.chunks(*wire.sse_frames(response)).close

  def request
    Lain::Request.new(model: "claude-opus-4-8", max_tokens: 64,
                      messages: [{ role: "user", content: "hi" }], stream: true)
  end

  # Both keys go on the CONFIG. Handing `config:` to the constructor skips
  # `#build_config` entirely, which is where `api_key:`/`api_base:` are read --
  # so a spec that passes both `config:` and `api_key:` silently sends no key.
  def config_for(upstream)
    zero_retry_config.tap do |config|
      config.anthropic_api_base = upstream.url
      config.anthropic_api_key = "test-key"
    end
  end

  def bedrock_config_for(upstream)
    zero_retry_config.tap do |config|
      config.bedrock_api_base = upstream.url
      config.bedrock_api_key = "test-token"
      config.bedrock_region = "us-east-1"
    end
  end

  def types_of(response) = response.content.map { |block| block["type"] }

  describe "a block the retry does not reopen" do
    it "is discarded rather than spliced into the response" do
      response = nil
      served = nil
      StreamingUpstream.sse(severed_prefix(rich, frames: 6), whole(lean)) do |upstream|
        response = described_class.new(config: config_for(upstream)).complete(request)
        served = upstream.requests.size
      end

      expect(served).to eq(2)
      expect(types_of(response)).to eq(%w[text])
      expect(response.text).to eq("the retry")
    end

    # The form that matters. A `tool_use` the model never finished asking for is
    # not duplicated prose: the Agent loop would run it, and the turn commits to
    # a content-addressed Timeline as permanent history.
    it "carries no phantom tool call from the attempt that was abandoned" do
      response = nil
      StreamingUpstream.sse(severed_prefix(rich, frames: 6), whole(lean)) do |upstream|
        response = described_class.new(config: config_for(upstream)).complete(request)
      end

      expect(response.tool_uses).to be_empty
      expect(response.content.map { |block| block["id"] }).not_to include("toolu_orphan")
    end

    # The envelope lied too: `stop_reason` and usage described the retry while
    # the content described both attempts, which is why nothing surfaced.
    it "reports the retry's stop_reason over content that is only the retry's" do
      response = nil
      StreamingUpstream.sse(severed_prefix(rich, frames: 6), whole(lean)) do |upstream|
        response = described_class.new(config: config_for(upstream)).complete(request)
      end

      expect(response).to stop_with(:end_turn)
      expect(response.content.size).to eq(1)
    end
  end

  describe "a stream that needs no retry" do
    it "keeps every block of a multi-block response, in order" do
      response = nil
      served = nil
      StreamingUpstream.sse(whole(rich)) do |upstream|
        response = described_class.new(config: config_for(upstream)).complete(request)
        served = upstream.requests.size
      end

      expect(served).to eq(1)
      expect(types_of(response)).to eq(%w[text tool_use])
      expect(response.tool_uses.first["input"]).to eq({ "text" => "hi" })
    end
  end

  # One class, two providers: {Provider::Bedrock} builds the same
  # {Anthropic::StreamAssembler} over its own transport. That transport threads
  # no request context at all -- no WAL frame, no retry object -- so a fix driven
  # off the retry hook would not reach this arm. This is the criterion that says
  # whether it did.
  describe Lain::Provider::Bedrock do
    it "discards the same orphaned block over the Mantle transport" do
      response = nil
      served = nil
      StreamingUpstream.sse(severed_prefix(rich, frames: 6), whole(lean)) do |upstream|
        response = described_class.new(config: bedrock_config_for(upstream)).complete(request)
        served = upstream.requests.size
      end

      expect(served).to eq(2)
      expect(types_of(response)).to eq(%w[text])
      expect(response.tool_uses).to be_empty
    end
  end
end
