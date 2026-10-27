# frozen_string_literal: true

module Lain
  module Bench
    # Compares {Grader::Rubric::Scale} shapes on findings whose truth is already known: which
    # shape lets a false finding survive least often. The one count that matters is a false
    # finding that survived, with its one-sided 95% (Clopper-Pearson) upper bound. Accuracy is
    # reported beside it and never gates, because a judge that refutes everything is accurate
    # on a set that is mostly false. Brier is printed only where the score is a probability.
    class JudgeScale
      DEFAULT_SCALES = Grader::Rubric::Scale::NAMES

      WITHHELD = "Brier withheld: scores are not probabilities"

      # @!attribute accuracy
      #   @return [Float] the share of findings whose survival matched their label
      # @!attribute wrong_survived
      #   @return [Integer] false findings the judge let through
      # @!attribute wrong_bound
      #   @return [Float, nil] one-sided 95% upper bound on the wrong-survive rate; nil with no false findings
      # @!attribute brier
      #   @return [Float, nil] score against label; nil for a scale whose scores are not probabilities
      Row = Data.define(:scale, :n, :accuracy, :wrong_survived, :wrong_bound, :brier)

      # @param path [String] a JSONL file of `finding`, `label` (true or false) and `synthetic` rows
      # @return [Array<Hash>]
      # @raise [CLI::Refusal] on a line that is not JSON or whose label is not true or false, naming the line
      def self.load(path)
        numbered = File.foreach(path).with_index(1).reject { |text, _| text.strip.empty? }
        rows = numbered.map { |text, line| parsed(text, line) }
        raise CLI::Refusal, "no findings in #{path}" if rows.empty?

        rows
      end

      def self.parsed(text, line)
        row = Journal.parse(text)
        raise CLI::Refusal, "line #{line}: not a JSON object" unless row.is_a?(Hash)
        raise CLI::Refusal, "line #{line}: finding must be a non-blank string" if Blankness.blank?(row["finding"])
        return row if [true, false].include?(row["label"])

        raise CLI::Refusal, "line #{line}: label must be true or false, got #{row["label"].inspect}"
      end
      private_class_method :parsed

      # @param findings [Array<Hash>] as {.load} returns
      # @param scales [Array<Symbol>]
      # @param refuter_for [#call] scale => an object answering `#refute(finding)` with a {Grader::Grade}
      # @raise [CLI::Refusal] on a scale outside {Grader::Rubric::Scale::NAMES}
      def initialize(findings:, scales:, refuter_for:)
        unknown = scales.map(&:to_sym) - Grader::Rubric::Scale::NAMES
        if unknown.any?
          raise CLI::Refusal,
                "unknown scale #{unknown.join(", ")}; one of #{Grader::Rubric::Scale::NAMES.join(", ")}"
        end

        @findings = findings
        @scales = scales.map(&:to_sym)
        @refuter_for = refuter_for
      end

      # @return [Array<Row>]
      def rows = @scales.map { |scale| row(scale, judged(scale)) }

      # @return [String]
      def report
        header = "#{@findings.size} labelled findings, #{false_count} false"
        [header, *rows.map { line(_1) }].join("\n")
      end

      private

      def false_count = @findings.count { !_1.fetch("label") }

      def judged(scale)
        refuter = @refuter_for.call(scale)
        @findings.map { |entry| [entry, refuter.refute(entry.fetch("finding"))] }
      end

      def row(scale, graded)
        wrong = graded.count { |entry, grade| !entry.fetch("label") && grade.pass? }
        Row.new(scale:, n: graded.size, accuracy: graded.count do |entry, grade|
          grade.pass? == entry.fetch("label")
        end.fdiv(graded.size),
                wrong_survived: wrong, wrong_bound: bound(wrong), brier: brier(scale, graded))
      end

      def bound(wrong) = false_count.zero? ? nil : Compare::Stats.clopper_pearson_upper(wrong, false_count)

      def brier(scale, graded)
        return nil unless Grader::Rubric::Scale.fetch(scale).probability?

        forecasts = graded.map { |_, grade| grade.score.to_f }
        Compare::Stats.brier(forecasts, graded.map { |entry, _| entry.fetch("label") ? 1.0 : 0.0 })
      end

      def line(row)
        [row.scale, "n=#{row.n}", "survives at #{Grader::Rubric::Scale.fetch(row.scale).survives_at}",
         "accuracy #{percent(row.accuracy)}", survivors(row),
         row.brier ? format("Brier %.4f", row.brier) : WITHHELD].join("  ")
      end

      def survivors(row)
        return "no false findings, so nothing measured" if row.wrong_bound.nil?

        "wrong survived #{row.wrong_survived} of #{false_count} " \
          "(one-sided 95% upper bound #{percent(row.wrong_bound)})"
      end

      def percent(rate) = "#{format("%.1f", rate * 100)}%"
    end
  end
end
