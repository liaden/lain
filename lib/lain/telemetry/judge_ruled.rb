# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # The verdict is a closed set; `call` is interned.
      class JudgeRuled < Declarative::Carrier
        VERDICTS = %w[approved denied remembered human_remembered].freeze

        attribute :call, :lain_interned
        attribute :verdict, :lain_interned
        validates :verdict, inclusion: { in: VERDICTS, message: ->(_record, data) { unknown(data[:value]) } }

        def self.unknown(value) = "is unknown: got #{value.inspect}, expected one of #{VERDICTS.join(", ")}"
      end
    end

    JudgeRuled = Data.define(:call, :verdict)

    # A call the judge approved, denied or had approved earlier, or one a human's earlier yes let run, as a
    # human would read it: the tool, its input, and the verdict. Sent to the display channel so the transcript
    # can say who let the call run or stopped it; the escalation record already
    # holds the ruling.
    class JudgeRuled
      include Journalable

      VERDICTS = Carriers::JudgeRuled::VERDICTS

      def initialize(call:, verdict:) = super(**Carriers::JudgeRuled.settle!(call:, verdict:))
    end
  end
end
