# frozen_string_literal: true

module Lain
  class Arm
    class Driver
      # Kept apart from the per-metric folds because these read pass/fail and the attempt order of each task,
      # which a flat list of runs has already thrown away.
      Outcomes = Data.define(:attempts_by_arm, :attempts) do
        def sections = [pass_k, rounds_to_pass, cost_per_solved]

        private

        def tasks_of(name) = attempts_by_arm.fetch(name)

        def passed?(result) = !result.is_a?(TaskFailure) && result.grade.pass?

        def pass_k
          rows = attempts_by_arm.map do |name, tasks|
            held = tasks.count { |tries| tries.all? { |result| passed?(result) } }
            [name, tasks.size.to_s, attempts.to_s, format("%.2f", held.fdiv(tasks.size))]
          end
          "pass^k\n#{Compare::Table.new(headers: %w[arm tasks k pass^k], rows:)}"
        end

        def rounds_to_pass
          rounds = attempts_by_arm.transform_values { |tasks| tasks.filter_map { |tries| first_pass(tries) } }
          rows = rounds.map { |name, values| rounds_row(name, values, tasks_of(name).size) }
          notes = rounds.map { |name, values| late_note(name, values, tasks_of(name).size) }
          ["rounds to pass\n#{Compare::Table.new(headers: Compare::ArmFold::HEADERS, rows:)}",
           *notes.map { |note| "  #{note}" }].join("\n")
        end

        def first_pass(tries) = tries.index { |result| passed?(result) }&.succ

        def rounds_row(name, values, total)
          return STAT_FOLD.absent_row(name, count: "0 of #{total}", marker: "no task passed") if values.empty?

          STAT_FOLD.row(name, Compare::Distribution.new(values), fmt: ->(value) { format("%.1f", value) })
        end

        def late_note(name, values, total)
          late = values.count { |rounds| rounds >= LATE_ROUNDS }
          "#{name}: #{late} of #{total} tasks needed #{LATE_ROUNDS} or more rounds"
        end

        def cost_per_solved
          label = "cost per solved task (USD)"
          priced = attempts_by_arm.transform_values do |tasks|
            tasks.flatten.grep_v(TaskFailure).map do |run|
              run.compare_run.price
            end
          end
          unpriced = priced.values.flatten.select(&:refuses?)
          return "#{label}\n  #{Compare::Cost::Unpriced.describe(unpriced)}" if unpriced.any?

          rows = priced.map { |name, prices| cost_row(name, prices) }
          ["#{label}\n#{Compare::Table.new(headers: %w[arm spent passed cost], rows:)}", *excluded_notes].join("\n")
        end

        # A failed attempt was paid for but its spend died with the exception, so the cost above is a floor.
        def excluded_notes
          attempts_by_arm.filter_map do |name, tasks|
            lost = tasks.flatten.count { |result| result.is_a?(TaskFailure) }
            "  #{name}: spend excludes #{lost} failed #{lost == 1 ? "attempt" : "attempts"}" if lost.positive?
          end
        end

        def cost_row(name, prices)
          spent = prices.sum(BigDecimal(0), &:amount)
          passes = tasks_of(name).flatten.count { |result| passed?(result) }
          [name, format("%.6f", spent), passes.to_s, passes.zero? ? "no task solved" : format("%.6f", spent / passes)]
        end
      end
    end
  end
end
