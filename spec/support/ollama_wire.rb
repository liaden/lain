# frozen_string_literal: true

require "json"

# Turns a Lain::Response back into the Ollama `/api/chat` non-streaming JSON body
# that would have produced it, so a canned response can be replayed through the
# REAL Provider::Ollama decode path -- content reassembly, tool-input handling,
# and done_reason -> stop_reason normalization -- with no cassette and no
# network. This is the Ollama analogue of spec/support/anthropic_sse.rb, and it
# is what lets the shared "a Lain::Provider" parity group run against
# Provider::Ollama exactly the way it runs against Mock and AnthropicRaw.
#
# Two Ollama-specific wrinkles the serializer bridges deliberately:
#
#   * The native wire has NO tool-call id (correlation is by tool_name only).
#     The parity harness carries the canned id in a non-standard "id" sibling of
#     "function" so Provider::Ollama's honor-a-wire-id branch round-trips it --
#     exactly how AnthropicSSE replays ids through a wire that DOES have them.
#     Real Ollama omits the field, and the decoder synthesizes there instead
#     (see ollama_spec's synthesis example).
#
#   * done_reason's real enum is only "stop"/"length"/"". On a tool-call turn
#     real Ollama still says "stop", so the serializer emits "stop" whenever the
#     response carries tool calls -- which is what forces the decoder to derive
#     :tool_use from the calls' presence, not from done_reason (belief (c)).
module OllamaWire
  module_function

  # @return [Hash] the non-streaming JSON body shape for this response
  def body_hash(response)
    { "model" => response.model || Lain::Provider::Ollama::DEFAULT_MODEL,
      "message" => message_hash(response),
      "done" => true,
      "done_reason" => done_reason(response),
      "prompt_eval_count" => response.usage.input_tokens,
      "eval_count" => response.usage.output_tokens }
  end

  def message_hash(response)
    message = { "role" => "assistant", "content" => text_of(response) }
    thinking = thinking_of(response)
    message["thinking"] = thinking unless thinking.empty?
    calls = tool_calls_of(response)
    message["tool_calls"] = calls unless calls.empty?
    message
  end

  def text_of(response)
    response.blocks_of_type("text").map { |block| block["text"] }.join
  end

  def thinking_of(response)
    response.blocks_of_type("thinking").map { |block| block["thinking"] }.join
  end

  def tool_calls_of(response)
    response.tool_uses.map do |tool_use|
      { "id" => tool_use["id"], "function" => { "name" => tool_use["name"], "arguments" => tool_use["input"] } }
    end
  end

  # Real Ollama: "stop" even on tool-call turns. Otherwise map the two enum
  # values it can express and pass everything else through verbatim, so the
  # parity group's :refusal / :pause_turn / :stop_sequence canned reasons reach
  # the decoder's StopReason.normalize fallback (mirroring AnthropicSSE, which
  # passes stop_reason through untouched).
  def done_reason(response)
    return "stop" unless response.tool_uses.empty?

    case response.stop_reason
    when :end_turn then "stop"
    when :max_tokens then "length"
    else response.stop_reason.to_s
    end
  end

  # A transport double: returns a scripted body per sync call, repeating the last
  # once exhausted (matching Provider::Mock's behavior).
  def queue_transport(responses)
    QueueTransport.new(Array(responses))
  end

  # See .queue_transport.
  class QueueTransport
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def sync_post(payload, _headers = {})
      @calls << payload
      Struct.new(:body).new(OllamaWire.body_hash(next_response))
    end

    # The streaming counterpart: the Context the parity group builds defaults
    # `stream: true`, so the seven gates now run through the NDJSON decode path.
    # The whole body is serialized as one x-ndjson line (already carrying
    # `done: true`); StreamAssembler reassembles it to the same shape sync_post
    # returns, so both paths land on identical Responses.
    def stream(payload, _headers = {})
      @calls << payload
      yield "#{JSON.generate(OllamaWire.body_hash(next_response))}\n"
    end

    private

    def next_response
      raise "OllamaWire::QueueTransport ran out of responses" if @responses.empty?

      @responses.size > 1 ? @responses.shift : @responses.first
    end
  end
end
