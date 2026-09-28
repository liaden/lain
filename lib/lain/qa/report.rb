# frozen_string_literal: true

require "json"

module Lain
  module QA
    Report = Data.define(:subject, :findings, :tiers_run, :escalations, :unsettled) do
      # @param text [String] the QA child's whole answer
      # @param subject [String] what was checked, stamped by the caller, so a
      #   `subject` inside the fence is ignored
      # @return [Report]
      # @raise [MalformedReport] for every shape that is not a report, findings
      #   included -- a caller rescuing a report parse rescues this
      def self.parse(text, subject:)
        blocks = QA.readable(text).scan(Report::PATTERN)
        raise MalformedReport, Report::NO_BLOCK if blocks.empty?

        body = blocks.last.first
        raise MalformedReport, Report::EMPTY_BLOCK if Blankness.blank?(body)

        from_wire(JSON.parse(body), subject:)
      rescue JSON::ParserError => e
        raise MalformedReport, "#{Report::NOT_JSON}: #{e.message}"
      rescue MalformedFinding => e
        raise MalformedReport, "#{Report::BAD_FINDING}: #{e.message}"
      end

      # The guard {Answer.parse} has eleven lines away, and the one this file
      # was missing: without it a fence holding a bare JSON string takes
      # `String#[]`'s substring branch, finds nothing, and renders a clean PASS.
      def self.from_wire(wire, subject:)
        raise MalformedReport, format(Report::NOT_AN_OBJECT, got: wire.class) unless wire.is_a?(Hash)

        new(subject:, findings: Array(wire["findings"]).map { |finding| Finding.from_h(finding) },
            tiers_run: Array(wire["tiers_run"]), escalations: Array(wire["escalations"]),
            unsettled: Array(wire["unsettled"]))
      end
      private_class_method :from_wire

      def initialize(subject:, findings: [], tiers_run: [], escalations: [], unsettled: [])
        super(subject: QA.word!(subject, field: "subject", refusal: MalformedReport), findings: only_findings(findings),
              tiers_run: rungs(tiers_run), escalations: lines(escalations, "escalations"),
              unsettled: lines(unsettled, "unsettled"))
      end

      # THREE states, not two booleans. `passed?` is what a hurried caller
      # reaches for, and a report with five unsettled criteria answers true to
      # it -- which is the silent pass reintroduced at the API. The predicates
      # below read this rather than deciding anything of their own.
      #
      # @return [Symbol] `:hold`, `:unsettled` or `:pass`
      def verdict
        return :hold unless holding.empty?

        unsettled.empty? ? :pass : :unsettled
      end

      # Nothing found holds the work back. Minor findings do not, and neither
      # does an unsettled criterion: a pass is about defects, and a criterion
      # nothing settled is not a defect anybody observed.
      def passed? = verdict != :hold

      # Passed AND with nothing left owing. The pair is the distinction the
      # whole ladder is for: a pass over a criterion no rung could settle is a
      # weaker claim than a pass over one that was checked.
      def clean? = verdict == :pass

      def holding = findings.select(&:holds?)

      # This report with +others+ found before it -- the structural rung's
      # findings, which run in-process ahead of any model.
      def prepend(others) = with(findings: others + findings, tiers_run: ([TIERS.first] + tiers_run).uniq)

      # The wire form {parse} reads, so nothing downstream invents the inverse.
      def to_h
        { "subject" => subject, "findings" => findings.map(&:to_h), "tiers_run" => tiers_run,
          "escalations" => escalations, "unsettled" => unsettled }
      end

      # @return [String] the report file a human and the implementer read
      def to_markdown
        [header, *escalation_lines, *unsettled_lines, "",
         *findings.each_with_index.map { |finding, index| entry(finding, index) }].join("\n")
      end

      private

      # A non-Finding here is not merely wrong, it is unshareable: the value
      # stops answering `Ractor.shareable?` and the deep-frozen guarantee goes
      # with it.
      def only_findings(findings)
        wrong = findings.grep_v(Finding).map(&:class).uniq
        raise MalformedReport, format(Report::NOT_FINDINGS, got: wrong.join(", ")) unless wrong.empty?

        findings.dup.freeze
      end

      def rungs(tiers)
        named = lines(tiers, "tiers_run")
        unknown = named - TIERS
        raise MalformedReport, format(Report::UNKNOWN_RUNG, got: unknown.join(", ")) unless unknown.empty?

        named
      end

      def lines(values, field)
        values.each_with_index
              .map { |value, index| QA.word!(value, field: "#{field}[#{index}]", refusal: MalformedReport) }
              .freeze
      end

      # States what it RAN, not only what it found: a pass nobody can audit --
      # which rungs answered, what each escalation cost -- is a claim without a
      # method behind it.
      def header
        "# QA report: #{subject}\n\nVerdict: #{rendered_verdict}. Tiers run: #{tiers_run.join(", ")}. " \
          "Findings: #{findings.size}. Unsettled: #{unsettled.size}."
      end

      def rendered_verdict
        { hold: "HOLD (#{holding.size} holding)", unsettled: "PASS (#{unsettled.size} unsettled)", pass: "PASS" }
          .fetch(verdict)
      end

      def escalation_lines
        escalations.empty? ? [] : ["", "## Escalations", *escalations.map { |line| "- #{line}" }]
      end

      def unsettled_lines
        unsettled.empty? ? [] : ["", "## Unsettled criteria", *unsettled.map { |criterion| "- #{criterion}" }]
      end

      def entry(finding, index)
        <<~ENTRY
          ## #{index + 1}. [#{finding.severity}] #{finding.summary}

          - criterion: #{finding.criterion}
          - found at: #{finding.tier}
          - evidence: #{finding.evidence}
          - reproduce: #{finding.reproduction}
        ENTRY
      end
    end

    # What one QA pass came to: the findings, which rungs of the ladder ran,
    # every escalation it took with the rule that fired, and the criteria
    # nothing settled -- so a reader can see what the pass spent and why, not
    # only what it found.
    #
    # The QA child answers in prose and ends with ONE fenced block holding this
    # value as JSON, so the LAST fence is the report, for {Answer}'s reason.
    # Only the fence is read: the prose around it is for the human, and a child
    # whose answer has no fence produced no report, which is refused rather than
    # read as a clean pass. A pass with nothing to say is still representable --
    # the fence carries empty lists -- so the refusal costs no legitimate
    # report; a fence a child opened and left empty is refused too, in words
    # rather than in a JSON parser's column numbers.
    class Report
      FENCE = "qa-report"
      PATTERN = /^```#{FENCE}[ \t]*\r?\n(.*?)^```[ \t]*$/m

      NO_BLOCK = "the QA answer holds no ```#{FENCE} block, so it reported nothing".freeze
      EMPTY_BLOCK = "the QA answer's ```#{FENCE} block is empty, so it reported nothing".freeze
      NOT_AN_OBJECT = "the QA answer's report block must be an object, got %<got>s"
      NOT_JSON = "the QA answer's report block is not JSON"
      BAD_FINDING = "the QA answer's report block holds something that is not a finding"
      NOT_FINDINGS = "a report's findings must all be findings, got %<got>s"
      UNKNOWN_RUNG = "a report names a rung outside the ladder: %<got>s"
    end
  end
end
