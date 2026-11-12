# frozen_string_literal: true

module Lain
  module Notices
    # One `notify-feed <source> <title>` run per note, the body on stdin so it
    # never meets an argv limit. A failure goes to the notes sink and never
    # into the caller, which is a turn or a runner with nothing to do about it;
    # it is said once, since a broken feed fails every note after the first.
    class Feed
      TIMEOUT = 2

      # @param program [String] the notify-feed executable
      # @param notes [#puts] where a failure is named
      # @param shell_out [#new] builds the command, `Shell::Out`'s shape
      def initialize(program:, notes:, shell_out: Shell::Out)
        @program = program
        @shell_out = shell_out
        @notes = notes
        @reported = Concurrent::AtomicBoolean.new
      end

      # @return [nil]
      def call(source, title, body = "")
        status = run(source, title, body).exitstatus
        report("exited #{status.inspect}") unless status.eql?(0)
        nil
      rescue StandardError => e
        report("failed: #{e.message}")
        nil
      end

      private

      # The notices poll thread and a turn can both fail a note at once.
      def report(failure)
        @notes.puts("#{@program} #{failure}") if @reported.make_true
      end

      def run(source, title, body)
        @shell_out.new(@program, source, title, input: body, timeout: TIMEOUT).run_command
      end
    end
  end
end
