# frozen_string_literal: true

module Lain
  module Telemetry
    JudgeRuled = Data.define(:call, :verdict)

    # A call the judge approved or denied, as a human would read it: the tool,
    # its input, and the verdict. Sent to the display channel so the transcript
    # can say who let the call run or stopped it; the escalation record already
    # holds the ruling.
    class JudgeRuled
      include Journalable

      VERDICTS = %w[approved denied].freeze

      def initialize(call:, verdict:)
        unless VERDICTS.include?(verdict)
          raise ArgumentError, "unknown judge verdict #{verdict.inspect}; expected one of #{VERDICTS.inspect}"
        end

        super(call: call.to_s.dup.freeze, verdict: -verdict)
      end
    end
  end
end
