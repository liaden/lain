# frozen_string_literal: true

require "json"

module Lain
  class Provider
    class AnthropicRaw < Provider
      # Reassembles Anthropic's SSE events into the FULL, ordered content-block
      # list -- text, thinking, and tool_use alike -- keyed by the wire `index`.
      #
      # This is the mutation the fork exists for. The vendored
      # {Provider::HTTP::StreamAccumulator} flattens: it joins every text block
      # into one String, joins every thinking block, and keeps only the *first*
      # thinking block's signature. That destroys the content array, and gate 1
      # requires committing it whole -- a second thinking block's signature that
      # goes missing corrupts the very next turn, because Anthropic rejects a
      # thinking block replayed without its verbatim signature.
      #
      # So this assembler keeps each block separate under its own index and
      # applies deltas to it in place, which is also what makes `input_json_delta`
      # reassembly correct: a tool_use's `input` arrives as a run of JSON *string*
      # fragments, possibly split mid-token across TCP reads, and only concatenating
      # them by index and parsing once at `content_block_stop` recovers the object.
      class StreamAssembler
        # The completed turn: ordered wire blocks plus the envelope metadata the
        # response builder needs. `usage` stays a raw Hash so nil cache fields
        # survive to be normalized in one place.
        Assembled = Data.define(:id, :model, :stop_reason, :content, :usage)

        # Event type -> handler. A table rather than a `case` so adding an event
        # is one line and the dispatcher stays flat.
        EVENT_HANDLERS = {
          "message_start" => :on_message_start,
          "content_block_start" => :on_block_start,
          "content_block_delta" => :on_block_delta,
          "content_block_stop" => :on_block_stop,
          "message_delta" => :on_message_delta
        }.freeze

        # Delta type -> handler, same reasoning.
        DELTA_HANDLERS = {
          "text_delta" => :append_text,
          "thinking_delta" => :append_thinking,
          "signature_delta" => :append_signature,
          "input_json_delta" => :append_input_json
        }.freeze

        def initialize
          @blocks = {}
          @input_buffers = {}
          @id = nil
          @model = nil
          @stop_reason = nil
          @usage = {}
        end

        # @param data [Hash] one parsed Anthropic SSE event
        def add(data)
          handler = EVENT_HANDLERS[data["type"]]
          send(handler, data) if handler
          self
        end

        # @return [Assembled]
        def result
          Assembled.new(id: @id, model: @model, stop_reason: @stop_reason,
                        content: @blocks.keys.sort.map { |index| @blocks[index] }, usage: @usage)
        end

        private

        def on_message_start(data)
          message = data["message"] || {}
          @id = message["id"]
          @model = message["model"]
          merge_usage(message["usage"])
        end

        # Seed the block from its skeleton so ordering and identity are fixed the
        # moment it opens; deltas only ever fill it in.
        def on_block_start(data)
          index = data["index"]
          skeleton = data["content_block"] || {}
          @blocks[index] = seed_block(index, skeleton)
        end

        def seed_block(index, skeleton)
          case skeleton["type"]
          when "text" then { "type" => "text", "text" => +(skeleton["text"] || "") }
          when "thinking" then seed_thinking(skeleton)
          when "tool_use" then seed_tool_use(index, skeleton)
          when "redacted_thinking" then { "type" => "redacted_thinking", "data" => skeleton["data"] }
          else skeleton
          end
        end

        def seed_thinking(skeleton)
          { "type" => "thinking", "thinking" => +(skeleton["thinking"] || ""),
            "signature" => +(skeleton["signature"] || "") }
        end

        def seed_tool_use(index, skeleton)
          @input_buffers[index] = +""
          { "type" => "tool_use", "id" => skeleton["id"], "name" => skeleton["name"], "input" => {} }
        end

        def on_block_delta(data)
          index = data["index"]
          return if @blocks[index].nil?

          delta = data["delta"] || {}
          handler = DELTA_HANDLERS[delta["type"]]
          send(handler, index, delta) if handler
        end

        def append_text(index, delta) = @blocks[index]["text"] << delta["text"].to_s
        def append_thinking(index, delta) = @blocks[index]["thinking"] << delta["thinking"].to_s
        def append_signature(index, delta) = @blocks[index]["signature"] << delta["signature"].to_s
        def append_input_json(index, delta) = @input_buffers[index] << delta["partial_json"].to_s

        # An empty argument buffer is `{}`, matching the accumulator's rule; a
        # non-empty one is parsed exactly once, here, so nothing above the Provider
        # ever sees the raw String (the Response#tool_uses contract).
        def on_block_stop(data)
          buffer = @input_buffers.delete(data["index"])
          return if buffer.nil?

          @blocks[data["index"]]["input"] = buffer.empty? ? {} : JSON.parse(buffer)
        end

        def on_message_delta(data)
          @stop_reason = data.dig("delta", "stop_reason") || @stop_reason
          merge_usage(data["usage"])
        end

        # message_start carries input and cache counts; message_delta carries the
        # final output_tokens. Later non-nil values win so the totals are complete.
        def merge_usage(usage)
          return unless usage.is_a?(Hash)

          usage.each { |key, value| @usage[key] = value unless value.nil? }
        end
      end
    end
  end
end
