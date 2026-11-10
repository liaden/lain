# frozen_string_literal: true

require_relative "example_count"

module TestMap
  # Compile first: suite:files loads lain, and a fresh worktree has no lain.so.
  class SubsetRun
    COMPILE = %w[bundle exec rake compile].freeze
    SUITE = %w[bundle exec rake suite:files].freeze

    def initialize(selection:, commands:, count:, out:, err:)
      @selection = selection
      @commands = commands
      @count = count
      @out = out
      @err = err
    end

    def call
      return 0 if @selection.specs.empty?

      announce
      compiled? && suite_green? ? 0 : 1
    rescue ExampleCount::DryRunFailed => e
      @err.puts e.message
      1
    end

    private

    def announce
      @selection.specs.each { |spec| @out.puts "#{spec}  (#{@selection.reasons[spec]})" }
    end

    def compiled?
      output, status = @commands.capture(COMPILE, env: {})
      @err.puts output unless status.success?
      status.success?
    end

    def suite_green?
      output, status = @commands.stream(SUITE, env: { "FILES" => @selection.specs.join("\n") })
      @err.puts "suite:files failed with exit #{status.exitstatus}" unless status.success?
      return false unless status.success?

      problem = @count.verify(output)
      @err.puts problem if problem
      problem.nil?
    end
  end
end
