# frozen_string_literal: true

module Lain
  module Notices
    # One `notify-feed <source> <title>` run per note, the body on stdin so it
    # never meets an argv limit. A failure goes to the notes sink and never
    # into the caller, which is a turn or a runner with nothing to do about it.
    class Feed
      TIMEOUT = 2

      # @param program [String] the notify-feed executable
      # @param shell_out [#new] builds the command, `Shell::Out`'s shape
      # @param notes [#puts] where a failure is named
      def initialize(program:, shell_out: Shell::Out, notes: Sink::Null.new)
        @program = program
        @shell_out = shell_out
        @notes = notes
      end

      # @return [nil]
      def call(source, title, body = "")
        status = run(source, title, body).exitstatus
        @notes.puts("notify-feed exited #{status.inspect}") unless status.eql?(0)
        nil
      rescue StandardError => e
        @notes.puts("notify-feed failed: #{e.message}")
        nil
      end

      private

      def run(source, title, body)
        @shell_out.new(@program, source, title, input: body, timeout: TIMEOUT).run_command
      end
    end
  end
end
