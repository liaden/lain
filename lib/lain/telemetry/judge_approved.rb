# frozen_string_literal: true

module Lain
  module Telemetry
    # A call the judge approved, as a human would read it: the tool and its
    # input. Sent to the display channel so the transcript can say who let the
    # call run; the escalation record already holds the ruling.
    JudgeApproved = Data.define(:call) do
      include Journalable

      def initialize(call:) = super(call: call.to_s.dup.freeze)
    end
  end
end
