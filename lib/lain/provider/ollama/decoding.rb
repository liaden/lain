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
      #
      # ONE COLLABORATOR, AND IT IS NOT DECLARED HERE: `#note_prose_tool_call`
      # reads `@journal`, which {Ollama} owns and defaults to the Null channel.
      # Named because a mixin cannot declare an ivar and a reader should not have
      # to find the owner by grep: an includer other than {Ollama} gets a
      # `NoMethodError` on nil. That is tolerable only while {Ollama} is the sole
      # includer -- if a second one ever appears, this reaches for a collaborator
      # it must instead be handed.
      module Decoding
        # MODEL-2: the shape `qwen3-coder:30b` writes when it expresses a tool
        # call as assistant TEXT instead of as a tool call -- a named opening
        # envelope, whatever it wrote for arguments, a well-formed close, and
        # the stray `</tool_call>` it emits with no opener to match.
        #
        # PRECISION IS A GOAL AND NOT A CONTRACT, and this pattern is where that
        # limit lives. A model EXPLAINING `<function=bash>` and a model EMITTING
        # it produce byte-identical text with no `tool_calls`, so the degenerate
        # case is undecidable and the answer can only be structural. Three
        # narrowings, each REASONED rather than measured -- see the measurement
        # below for why that distinction is not modesty:
        #
        #   * a well-formed `</function>`, so a `<function=` quoted mid-sentence
        #     is not read as a call the model finished expressing;
        #   * `\s*\z`, so the envelope must occupy the TRAILING content -- a
        #     model that closes it and goes on talking was writing ABOUT a call.
        #     Note what this does NOT reach: it declines an explanation only
        #     when something FOLLOWS the envelope (a closing fence, one more
        #     sentence). An illustration that ends the turn is still a fire, and
        #     that is the residual false positive named below, not an oversight.
        #     It is also the single point of OVER-FIT here: it is tuned to how
        #     qwen ends a turn, and a chat-template change is what would move it;
        #   * a lowercase snake_case identifier, which is the only spelling any
        #     tool in this harness has, so `<function=Enumerable#each>` in quoted
        #     source cannot read as a tool that was asked for.
        #
        # == What the narrowings were measured to be worth: nothing, so far
        #
        # Run over every recorded assistant turn in nine QA corpora (2026-08-17
        # to 2026-08-21): 1,267 turns, 181 of them carrying no `tool_calls`, 20
        # fires, and **0 of the 20 a false positive** on hand classification. But
        # a naive `/<function=/` scores THE SAME 20 -- the narrowings declined
        # nothing in that corpus, so their false-positive reduction is UNMEASURED
        # rather than demonstrated, and this comment must not be read as though
        # it were earned.
        #
        # The corpus cannot show it, by construction: `planning/qa/method.md`
        # tells the driver to RESTART the session at the first literal
        # `<function=`, so a turn in which the model merely discusses an envelope
        # essentially never gets recorded. The residual false positive is exactly
        # one shape -- a final turn whose last words are a complete, snake_case,
        # well-closed envelope written as illustration -- and a human reading
        # that text alone cannot classify it either. It is affordable only
        # because this record is JOURNAL-ONLY: a false positive costs a reader
        # one NDJSON line to dismiss, which is the whole reason the panel cut
        # the rendering path.
        #
        # A fourth narrowing -- the name being live in the request's own toolset
        # -- is deliberately NOT here: `#build_response` is handed the body and
        # not the Request, and reaching for one would put this decision above the
        # provider that owns its model family's failure modes. It would also have
        # bought nothing: all 20 corpus fires name a real lain tool.
        PROSE_TOOL_CALL = %r{
          <function=(?<tool_name>[a-z][a-z0-9_]*)>   # the envelope, naming a tool
          .*?                                        # whatever it wrote for arguments
          </function>                                # closed, not merely opened
          (?:\s*</tool_call>)?                       # the stray closer, with no opener
          \s*\z                                      # and nothing said after it
        }mx

        private

        def build_response(body)
          message = body["message"] || {}
          response = Response.new(id: nil, model: body["model"], content: decode_content(message),
                                  stop_reason: decode_stop_reason(body, message), usage: build_usage(body), raw: body)
          note_prose_tool_call(body, message)
          response
        end

        # The witness for a turn that decoded perfectly and asked for nothing.
        # A prose tool call carries no `tool_calls`, so #decode_stop_reason
        # answers :end_turn and the turn lands on the HEALTHY arm of
        # {Agent::LoopMachine} -- nothing above here can tell it from a model
        # that simply finished talking, which is why the reading has to be made
        # in the provider that knows this model family and journaled where a
        # reader can grep for it.
        #
        # Journal-only and deliberately so: this REPORTS, it does not repair.
        # Salvaging the envelope would execute a call the model never properly
        # expressed, and the approval gate is no help when the parse itself is
        # what is wrong. The Response is already built when this runs, so the
        # record witnesses a decode that succeeded rather than one that raised,
        # and the turn reaches the Timeline exactly as it did before.
        def note_prose_tool_call(body, message)
          envelope = prose_tool_call(message)
          return if envelope.nil?

          @journal << Telemetry::MalformedResponse.new(kind: :prose_tool_call, model: body["model"],
                                                       tool_name: envelope[:tool_name], excerpt: envelope[0])
        end

        # nil unless the message asked for nothing AND ends in a closed
        # envelope. The tool_calls test comes first because it is the cheap,
        # total one: a message that made a real call is not malformed however
        # its text reads, and a model may legitimately discuss an envelope in
        # the same turn it calls a tool properly.
        def prose_tool_call(message)
          return nil unless Array(message["tool_calls"]).empty?

          PROSE_TOOL_CALL.match(message["content"].to_s)
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
