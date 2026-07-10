# frozen_string_literal: true

require "json"

# Turns a Lain::Response back into the Anthropic SSE events (and body) that would
# have produced it, so a canned response can be replayed through the REAL
# AnthropicRaw parsing path -- the block-preserving StreamAssembler and the
# response builder -- with no cassette and no network. This is what lets the
# shared "a Lain::Provider" parity group run against AnthropicRaw exactly the way
# it runs against Mock: hand it a sequence of Responses, get a provider that
# yields them in order when driven through a real Agent loop.
#
# It is a serializer, so a round trip (Response -> events -> Response) is a real
# assertion that the parse is the inverse of a plausible Anthropic stream.
module AnthropicSSE
  module_function

  # @return [Array<Hash>] the parsed SSE events for this response, in wire order
  def events(response)
    [message_start(response)] +
      response.content.each_with_index.flat_map { |block, index| block_events(block, index) } +
      [message_delta(response), { "type" => "message_stop" }]
  end

  # @return [String] the same events as a text/event-stream body
  def body(response)
    events(response).map { |event| "event: #{event["type"]}\ndata: #{JSON.generate(event)}\n\n" }.join
  end

  # @return [Hash] the non-streaming JSON body shape for this response
  def body_hash(response)
    { "id" => response.id || "msg_test", "model" => response.model || "claude-opus-4-8",
      "content" => response.content, "stop_reason" => response.stop_reason.to_s,
      "usage" => usage_hash(response.usage) }
  end

  # A transport double: replays a queue of Responses as SSE, one per stream/sync
  # call, repeating the last once exhausted (matching Provider::Mock's behavior).
  def queue_transport(responses)
    QueueTransport.new(Array(responses))
  end

  def message_start(response)
    { "type" => "message_start",
      "message" => { "id" => response.id || "msg_test", "model" => response.model || "claude-opus-4-8",
                     "usage" => usage_hash(response.usage) } }
  end

  def message_delta(response)
    { "type" => "message_delta", "delta" => { "stop_reason" => response.stop_reason.to_s },
      "usage" => { "output_tokens" => response.usage.output_tokens } }
  end

  def block_events(block, index)
    [{ "type" => "content_block_start", "index" => index, "content_block" => skeleton(block) }] +
      delta_events(block, index) +
      [{ "type" => "content_block_stop", "index" => index }]
  end

  def skeleton(block)
    case block["type"]
    when "text" then { "type" => "text", "text" => "" }
    when "thinking" then { "type" => "thinking", "thinking" => "" }
    when "tool_use" then { "type" => "tool_use", "id" => block["id"], "name" => block["name"], "input" => {} }
    else block
    end
  end

  def delta_events(block, index)
    case block["type"]
    when "text" then text_deltas(block, index)
    when "thinking" then thinking_deltas(block, index)
    when "tool_use" then tool_use_deltas(block, index)
    else []
    end
  end

  def text_deltas(block, index)
    return [] if block["text"].to_s.empty?

    [content_block_delta(index, "type" => "text_delta", "text" => block["text"])]
  end

  def thinking_deltas(block, index)
    deltas = []
    deltas << content_block_delta(index, "type" => "thinking_delta", "thinking" => block["thinking"]) unless
      block["thinking"].to_s.empty?
    deltas << content_block_delta(index, "type" => "signature_delta", "signature" => block["signature"]) unless
      block["signature"].to_s.empty?
    deltas
  end

  def tool_use_deltas(block, index)
    input = block["input"]
    return [] if input.nil? || input == {}

    [content_block_delta(index, "type" => "input_json_delta", "partial_json" => JSON.generate(input))]
  end

  def content_block_delta(index, delta)
    { "type" => "content_block_delta", "index" => index, "delta" => delta.compact }
  end

  def usage_hash(usage)
    { "input_tokens" => usage.input_tokens, "output_tokens" => usage.output_tokens,
      "cache_creation_input_tokens" => usage.cache_creation_input_tokens,
      "cache_read_input_tokens" => usage.cache_read_input_tokens }
  end

  # See .queue_transport.
  class QueueTransport
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def stream(payload, _headers = {}, &on_event)
      @calls << payload
      AnthropicSSE.events(next_response).each(&on_event)
      nil
    end

    def sync_post(payload, _headers = {})
      @calls << payload
      Struct.new(:body).new(AnthropicSSE.body_hash(next_response))
    end

    private

    def next_response
      raise "AnthropicSSE::QueueTransport ran out of responses" if @responses.empty?

      @responses.size > 1 ? @responses.shift : @responses.first
    end
  end
end
