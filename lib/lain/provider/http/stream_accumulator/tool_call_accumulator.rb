# frozen_string_literal: true

require "json"
require "securerandom"
require_relative "../tool_call"

# New code, not a port. Upstream's `StreamAccumulator` folds streamed
# tool-call-fragment tracking directly into itself
# (`accumulate_tool_calls`/`start_tool_call`/`append_tool_call_fragment`/
# `find_tool_call`), which pushed the class past this project's default
# `Metrics/ClassLength` (100) with no `Metrics/*` loosening allowed.
# Reassembling `input_json_delta` fragments by stream index into complete
# tool calls is a real, separate responsibility from text/thinking
# accumulation, so it is extracted rather than disabled away. Logic and
# behavior -- including `#parsed_arguments`'s empty-string-becomes-`{}` rule,
# which `stream_accumulator_spec.rb` pins down -- are unchanged from upstream.

module Lain
  class Provider
    module HTTP
      class StreamAccumulator
        # Assembles a sequence of streamed tool-call fragments -- keyed by
        # stream index until a fragment carries the real id -- into complete
        # {ToolCall}s with JSON-parsed arguments.
        class ToolCallAccumulator
          attr_reader :tool_calls

          def initialize(sink: Sink::Null.new, debug: false)
            @sink = sink
            @debug = debug
            @tool_calls = {}
            @latest_tool_call_id = nil
            @tool_call_ids_by_index = {}
          end

          def add(new_tool_calls)
            @sink.puts("Accumulating tool calls: #{new_tool_calls}") if @debug
            new_tool_calls.each do |stream_key, tool_call|
              if tool_call.id
                start_tool_call(stream_key, tool_call)
              else
                append_tool_call_fragment(stream_key, tool_call)
              end
            end
          end

          # @return [Hash{String => ToolCall}] arguments JSON-parsed
          def to_h
            tool_calls.transform_values do |tc|
              ToolCall.new(id: tc.id, name: tc.name, arguments: parsed_arguments(tc.arguments),
                           thought_signature: tc.thought_signature)
            end
          end

          private

          def parsed_arguments(arguments)
            return arguments unless arguments.is_a?(String)
            return {} if arguments.empty?

            JSON.parse(arguments)
          end

          def start_tool_call(stream_key, tool_call)
            tool_call_id = tool_call.id.empty? ? SecureRandom.uuid : tool_call.id
            tool_call_key = tool_call.id

            @tool_calls[tool_call_key] = ToolCall.new(
              id: tool_call_id,
              name: tool_call.name,
              arguments: initial_tool_call_arguments(tool_call),
              thought_signature: tool_call.thought_signature
            )
            @tool_call_ids_by_index[stream_key] = tool_call_key unless stream_key.nil?
            @latest_tool_call_id = tool_call_key
          end

          def initial_tool_call_arguments(tool_call)
            arguments = tool_call.arguments
            return +"" if arguments.nil? || (arguments.respond_to?(:empty?) && arguments.empty?)

            arguments
          end

          def append_tool_call_fragment(stream_key, tool_call)
            existing = find_tool_call(stream_key)
            return unless existing

            fragment = tool_call.arguments || ""
            existing.arguments << fragment
            return unless tool_call.thought_signature && existing.thought_signature.nil?

            existing.thought_signature = tool_call.thought_signature
          end

          def find_tool_call(stream_key)
            return @tool_calls[@latest_tool_call_id] if stream_key.nil?

            @tool_calls[@tool_call_ids_by_index[stream_key]] || @tool_calls[stream_key]
          end
        end
      end
    end
  end
end
