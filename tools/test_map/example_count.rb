# frozen_string_literal: true

module TestMap
  # A dead worker or a SystemExit truncates a parallel run that still exits 0,
  # so the printed total is checked against what a dry run counts.
  class ExampleCount
    class DryRunFailed < StandardError; end

    TOTAL = /^(\d+) examples?,/

    def initialize(files:, env:, commands:)
      @files = files
      @env = env
      @commands = commands
    end

    def expected
      @expected ||= dry_run_total
    end

    def verify(output)
      reported = total_in(output)
      return "no example total in the run's output; expected #{expected}" unless reported
      return nil if reported >= expected

      "run reported #{reported} examples, expected #{expected}"
    end

    private

    def dry_run_total
      out, status = @commands.capture(%w[bundle exec rspec --dry-run] + @files, env: @env)
      raise DryRunFailed, "dry run failed: #{out}" unless status.success?

      total_in(out) || raise(DryRunFailed, "no example count in the dry run output")
    end

    def total_in(text)
      count = text.scan(TOTAL).last&.first
      count && Integer(count)
    end
  end
end
