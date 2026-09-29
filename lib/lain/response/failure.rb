# frozen_string_literal: true

module Lain
  class Response
    # Why a reply is not an answer, read off the response itself so the pane, the
    # exit status, a subagent's parent and the agent's own record all say the
    # same words. The reasons are root-qualified because {Agent::StopReason}
    # shadows the wire enum inside that class, where this table used to live.
    #
    # The malformed messages name the journal record rather than one shape of
    # failure, because `Telemetry::MalformedResponse#kind` is where a second shape
    # would go, and the record is what carries the evidence.
    Failure = Data.define(:stop_reason, :message) do
      # A malformed turn's text is the raw envelope the provider refused, so
      # printing it as the answer would present the failure as the result.
      def withholds_text? = stop_reason == ::Lain::StopReason::MALFORMED
    end

    Failure::MESSAGES = { ::Lain::StopReason::MAX_TOKENS => "model hit max_tokens before finishing",
                          ::Lain::StopReason::REFUSAL => "model refused to continue",
                          ::Lain::StopReason::UNKNOWN => "unrecognized stop_reason from provider" }.freeze

    # Malformed has no entry above: its message depends on the text, so it is
    # one of these two. A provider fires it for a tool call written as prose AND for a turn
    # that said nothing at all; the text is what tells them apart.
    Failure::PROSE_CALL = "malformed response from model: a tool call written " \
                          "as prose, not an answer (see its malformed_response journal record)"
    Failure::SILENT = "malformed response from model: it said nothing at all, " \
                      "not an answer (see its malformed_response journal record)"
  end
end
