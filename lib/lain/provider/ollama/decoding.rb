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
      # decodes that one shape once. The path-parity assertions therefore live
      # in the CLASS's spec and cannot move here; `decoding_spec.rb` holds only
      # the readings this file makes of one already-assembled body.
      #
      # ONE COLLABORATOR, AND IT IS NOT DECLARED HERE: the two `#note_*` methods
      # read `@journal`, which {Ollama} owns. A mixin cannot declare an ivar, so
      # an includer that sets none gets a `NoMethodError` on nil. That is no
      # longer hypothetical -- `decoding_spec.rb` includes this module into a
      # throwaway class and assigns the ivar itself -- so the note stands as the
      # cost it names: a second PRODUCTION includer means this reaches for a
      # collaborator it must instead be handed.
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
        # {Lain::Blankness}'s set as a regex fragment. The anchor below and
        # `#said_nothing?` both decide what counts as nothing, on the same text,
        # one line apart -- `\s` would have left a zero-width character ending a
        # turn for one of them and not the other. Blankness answers over a WHOLE
        # string and this needs a fragment, which is why the set is spelled
        # twice; `decoding_spec.rb` pins the behaviour they must share.
        NOTHING_AFTER_IT = /[[:space:]\u{200B}-\u{200D}\u{2060}\u{FEFF}]*/

        PROSE_TOOL_CALL = %r{
          <function=(?<tool_name>[a-z][a-z0-9_]*)>   # the envelope, naming a tool
          .*?                                        # whatever it wrote for arguments
          </function>                                # closed, not merely opened
          (?:#{NOTHING_AFTER_IT}</tool_call>)?       # the stray closer, with no opener
          #{NOTHING_AFTER_IT}\z                      # and nothing said after it
        }mx

        # The reasons {Agent::LoopMachine} settles a run on as an ANSWER. A turn
        # that said nothing may not reach one, whatever the wire spelled: the
        # test is the reason the decode arrives at, because `StopReason.normalize`
        # admits the whole of `KNOWN` and an ollama-compatible server is free to
        # answer `"end_turn"` where ollama itself says `"stop"`.
        SETTLES_AS_ANSWER = [StopReason::END_TURN, StopReason::STOP_SEQUENCE].freeze

        private

        def build_response(body)
          message = body["message"] || {}
          envelope = prose_tool_call(message)
          silent = said_nothing?(message)
          response = Response.new(id: nil, model: body["model"], content: decode_content(message),
                                  stop_reason: decode_stop_reason(body, message, envelope, silent),
                                  usage: build_usage(body), raw: body)
          note_prose_tool_call(body, envelope) unless envelope.nil?
          note_empty_answer(body) if silent
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

        # The witness for a turn that decoded perfectly and SAID nothing --
        # every field a model can speak through left blank under an HTTP 200.
        # It carries no quote and names no tool because there was nothing to
        # quote: the absence is the whole finding, and the model is what a
        # reader needs to know which one went quiet.
        def note_empty_answer(body)
          @journal << Telemetry::MalformedResponse.new(kind: :empty_answer, model: body["model"])
        end

        # Every field a model can speak through, blank at once.
        def said_nothing?(message)
          Array(message["tool_calls"]).empty? &&
            Blankness.blank?(message["content"]) && Blankness.blank?(message["thinking"])
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
          blocks << { "type" => "thinking", "thinking" => message["thinking"] } unless
            Blankness.blank?(message["thinking"])
          blocks << { "type" => "text", "text" => message["content"] } unless Blankness.blank?(message["content"])
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
        # says, since "stop" is exactly the lie it tells. Silence may not settle
        # as an answer; every other reason is left saying what it said, because
        # a spent ceiling and a connection that closed already name a cause a
        # caller can act on.
        def decode_stop_reason(body, message, envelope, silent)
          return StopReason::TOOL_USE unless Array(message["tool_calls"]).empty?
          return StopReason::MALFORMED unless envelope.nil?

          reason = wire_stop_reason(body)
          silent && SETTLES_AS_ANSWER.include?(reason) ? StopReason::MALFORMED : reason
        end

        # The two enum values Ollama can express, with StopReason.normalize
        # closing the open enum ("" -> :unknown, and any load/unload edge string
        # likewise) so the mapping stays total.
        def wire_stop_reason(body)
          case body["done_reason"]
          when "stop" then StopReason::END_TURN
          when "length" then StopReason::MAX_TOKENS
          else StopReason.normalize(body["done_reason"])
          end
        end

        def build_usage(body)
          Usage.new(input_tokens: body["prompt_eval_count"], output_tokens: body["eval_count"])
        end
      end
    end
  end
end
