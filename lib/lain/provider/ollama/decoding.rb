# frozen_string_literal: true

module Lain
  class Provider
    class Ollama < Provider
      # The Ollama `/api/chat` body -> neutral {Lain::Response} decoding, and
      # {Encoding}'s counterpart: one mixin per wire direction, in the sibling
      # file each direction's reader expects to find it in.
      #
      # BE PRECISE ABOUT WHAT THIS IS: a FILE SPLIT, not a responsibility split.
      # Every method below is still on {Ollama}'s own (private) surface once
      # mixed in, exactly as {Encoding}'s are -- nothing was handed to a
      # collaborator and nothing became separately constructible. What the split
      # buys is reading order: the class stays about the ROUND TRIP (taking
      # capacity, choosing the streaming or the sync leg, wrapping errors) while
      # the wire's shape lives here, where the two open-enum quirks the native
      # API forces -- a synthesized tool-call id and a `done_reason` that never
      # says "tool_calls" -- are read together instead of a screen apart. An
      # object would be a worse answer, since every method here is a pure
      # function of the body Hash with no transport, no configuration and no
      # state to own.
      #
      # Private throughout: this is the class's own decoding, not a surface any
      # caller reaches for. Both legs converge on {#build_response}, which is
      # what makes streaming and non-streaming path parity structural rather
      # than asserted -- {StreamAssembler} reassembles the NDJSON lines into the
      # very Hash the non-streaming endpoint returns, and this decodes that one
      # shape once.
      #
      # An asymmetry worth knowing before hunting for a spec: `encoding_spec.rb`
      # exists and there is no `decoding_spec.rb`. These methods are exercised
      # through the class, in `ollama_spec.rb`, `ollama_streaming_spec.rb` and
      # `ollama_parity_spec.rb`, which is where they were spec'd before the
      # split and where the path-parity assertions have to live anyway.
      module Decoding
        private

        def build_response(body)
          message = body["message"] || {}
          Response.new(id: nil, model: body["model"], content: decode_content(message),
                       stop_reason: decode_stop_reason(body, message), usage: build_usage(body), raw: body)
        end

        # Order mirrors what a mixed assistant turn carries: reasoning first, then
        # visible text, then the calls -- thinking and text ride their own message
        # fields, tool_calls its own array.
        def decode_content(message)
          blocks = []
          blocks << { "type" => "thinking", "thinking" => message["thinking"] } unless blank?(message["thinking"])
          blocks << { "type" => "text", "text" => message["content"] } unless blank?(message["content"])
          Array(message["tool_calls"]).each_with_index { |call, index| blocks << tool_use_block(call, index) }
          blocks
        end

        # Ollama has no tool-call id, so one is synthesized from the call's
        # position -- deterministic and unique within the response, which is all
        # ToolRunner's id-keyed result matching needs (a later turn reusing the
        # same synthetic id is harmless: Encoding resolves tool_name in message
        # order, so each result names the tool its own turn called). A wire-
        # provided id is honored if one is ever present (forward-compat, and how
        # the parity harness replays canned ids); synthesis is the fallback.
        def tool_use_block(call, index)
          function = call["function"] || {}
          { "type" => "tool_use", "id" => call["id"] || "ollama-tool-#{index}",
            "name" => function["name"], "input" => parse_arguments(function["arguments"]) }
        end

        # Belief (b): native `/api/chat` returns arguments as a parsed object. The
        # String branch is belt-and-suspenders on Response#tool_uses' Hash
        # contract -- a String must never reach the Timeline.
        def parse_arguments(arguments)
          return arguments unless arguments.is_a?(String)

          JSON.parse(arguments)
        end

        # Presence of tool_calls forces :tool_use -- done_reason stays "stop" on a
        # tool turn. Otherwise map the two enum values Ollama can express and let
        # StopReason.normalize close the open enum ("" -> :unknown, and any
        # load/unload edge string likewise), so gate 6 stays total.
        def decode_stop_reason(body, message)
          return StopReason::TOOL_USE unless Array(message["tool_calls"]).empty?

          case body["done_reason"]
          when "stop" then StopReason::END_TURN
          when "length" then StopReason::MAX_TOKENS
          else StopReason.normalize(body["done_reason"])
          end
        end

        def build_usage(body)
          Usage.new(input_tokens: body["prompt_eval_count"], output_tokens: body["eval_count"])
        end

        def blank?(value)
          value.nil? || value == ""
        end
      end
    end
  end
end
