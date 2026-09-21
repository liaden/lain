# frozen_string_literal: true

module Lain
  class Provider
    class Ollama < Provider
      # The Ollama `/api/chat` body -> neutral {Lain::Response} decoding, and
      # {Encoding}'s counterpart.
      #
      # A FILE SPLIT, not a responsibility split: every method below is still on
      # {Ollama}'s own private surface once mixed in. What it buys is reading
      # order -- the class stays about the ROUND TRIP while the two open-enum
      # quirks the native API forces (a synthesized tool-call id, a
      # `done_reason` that never says "tool_calls") are read together. An object
      # would be a worse answer, since every method here is a pure function of
      # the body Hash with no transport, configuration or state to own.
      #
      # Both legs converge on {#build_response}, which is what makes path parity
      # structural rather than asserted: {StreamAssembler} reassembles the NDJSON
      # lines into the very Hash the non-streaming endpoint returns, and this
      # decodes that one shape once. There is no `decoding_spec.rb` for the same
      # reason -- these are exercised through the class, where the path-parity
      # assertions have to live.
      #
      # ONE COLLABORATOR, AND IT IS NOT DECLARED HERE: `#note_prose_tool_call`
      # reads `@journal`, which {Ollama} owns. A mixin cannot declare an ivar, so
      # an includer other than {Ollama} gets a `NoMethodError` on nil -- if a
      # second one ever appears, this reaches for a collaborator it must instead
      # be handed.
      module Decoding
        # The shape `qwen3-coder:30b` writes when it expresses a tool call as
        # assistant TEXT instead of as a tool call.
        #
        # PRECISION IS A GOAL AND NOT A CONTRACT. A model EXPLAINING
        # `<function=bash>` and a model EMITTING it produce byte-identical text
        # with no `tool_calls`, so the degenerate case is undecidable and the
        # answer can only be structural. Three narrowings, each REASONED rather
        # than measured:
        #
        #   * a well-formed `</function>`, so a `<function=` quoted mid-sentence
        #     is not read as a call the model finished expressing;
        #   * trailing-content anchoring, so a model that closes the envelope and
        #     goes on talking was writing ABOUT a call. An illustration that ENDS
        #     the turn is still a fire -- the residual false positive, not an
        #     oversight -- and this is the single point of OVER-FIT here, tuned
        #     to how qwen ends a turn;
        #   * a lowercase snake_case identifier, the only spelling any tool in
        #     this harness has, so `<function=Enumerable#each>` in quoted source
        #     cannot read as a tool that was asked for.
        #
        # == What the narrowings were measured to be worth: nothing, so far
        #
        # Over 1,267 recorded assistant turns from nine QA corpora, 181 of them
        # carrying no `tool_calls`: 20 fires, 0 false positives on hand
        # classification -- but a naive `/<function=/` scores THE SAME 20. The
        # narrowings declined nothing there, so their false-positive reduction is
        # UNMEASURED rather than demonstrated, and this comment must not be read
        # as though it were earned. The corpus cannot show it by construction,
        # since the QA driver restarts a session at the first literal
        # `<function=` and a turn merely DISCUSSING one is essentially never
        # recorded.
        #
        # The residual false positive now costs more than one NDJSON line. A
        # direct turn still renders its text in chat exactly as before; what
        # changes is that the run lands in `:failed`, so `--non-interactive`
        # exits 1, and a one-shot child's answer is replaced by an error result
        # for its parent. That is the price accepted for the other direction: a
        # missed prose call settled as a finished answer and was handed to a
        # parent as one, which nothing downstream could tell from success.
        #
        # Because the anchor needs the LAST closer, the lazy `.*?` spans from the
        # FIRST opener to it, so a turn holding two envelopes reports the first
        # one's tool name and quotes the excerpt from there.
        #
        # A fourth narrowing -- the name being live in the request's own toolset
        # -- is deliberately NOT here: `#build_response` is handed the body and
        # not the Request, and reaching for one would put this decision above the
        # provider that owns its model family's failure modes.
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
          envelope = prose_tool_call(message)
          response = Response.new(id: nil, model: body["model"], content: decode_content(message),
                                  stop_reason: decode_stop_reason(body, message, envelope),
                                  usage: build_usage(body), raw: body)
          note_prose_tool_call(body, envelope) unless envelope.nil?
          response
        end

        # The witness for a turn that decoded perfectly and asked for nothing. A
        # prose tool call carries no `tool_calls`, so the wire alone reads
        # :end_turn and nothing above here can tell it from a model that simply
        # finished talking -- which is why the reading is made in the provider
        # that knows this model family, and why it becomes the turn's stop
        # reason as well as this record: the record carries the evidence, the
        # stop reason is what fails the turn.
        #
        # It REPORTS and does not repair: salvaging the envelope would execute a
        # call the model never properly expressed, and the approval gate is no
        # help when the parse itself is what is wrong.
        def note_prose_tool_call(body, envelope)
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

        # Native `/api/chat` returns arguments as a parsed object; the String
        # branch is belt-and-suspenders on Response#tool_uses' Hash contract --
        # a String must never reach the Timeline.
        def parse_arguments(arguments)
          return arguments unless arguments.is_a?(String)

          JSON.parse(arguments)
        end

        # Presence of tool_calls forces :tool_use -- done_reason stays "stop" on
        # a tool turn. A prose envelope reads :malformed whatever done_reason
        # says, since "stop" is exactly the lie it tells. Otherwise map the two
        # enum values Ollama can express and let StopReason.normalize close the
        # open enum ("" -> :unknown, and any load/unload edge string likewise),
        # so the mapping stays total.
        def decode_stop_reason(body, message, envelope)
          return StopReason::TOOL_USE unless Array(message["tool_calls"]).empty?
          return StopReason::MALFORMED unless envelope.nil?

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
