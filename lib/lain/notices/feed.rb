# frozen_string_literal: true

module Lain
  module Notices
    # One `notify-feed <source> <title>` run per note, the body on stdin so it
    # never meets an argv limit. A failure goes to the notes sink and never
    # into the caller, which is a turn or a runner with nothing to do about it;
    # it is said once, since a broken feed fails every note after the first.
    class Feed
      TIMEOUT = 2

      # RUBYLIB binds a Ruby feed to lain's load path as RUBYOPT does, and {Exec::ChildEnv::SCRUB} lacks it.
      # Scrubbed rather than allowlisted, because a desktop notifier needs DISPLAY and DBUS_SESSION_BUS_ADDRESS.
      LOADER_NAMES = Regexp.union(Exec::ChildEnv::SCRUB, /\ARUBYLIB\z/)

      # @param program [String] the notify-feed executable
      # @param notes [#puts] where a failure is named
      # @param shell_out [#new] builds the command, `Shell::Out`'s shape
      # @param env [#to_h] the real process environment, which the program inherits; its Ruby loader names are unset
      def initialize(program:, notes:, shell_out: Shell::Out, env: ENV)
        @program = program
        @env = env
        @shell_out = shell_out
        @notes = notes
        @reported = Concurrent::AtomicBoolean.new
      end

      # @return [Boolean] whether the program ran and exited 0
      def call(source, title, body = "")
        status = run(source, title, body).exitstatus
        report("exited #{status.inspect}") unless status.eql?(0)
        status.eql?(0)
      rescue StandardError => e
        report("failed: #{e.message}")
        false
      end

      private

      # The notices poll thread and a turn can both fail a note at once.
      def report(failure)
        @notes.puts("#{@program} #{failure}") if @reported.make_true
      end

      def run(source, title, body)
        @shell_out.new(@program, source, title, input: body, timeout: TIMEOUT, environment: scrubbed).run_command
      end

      def scrubbed = @env.to_h.keys.grep(LOADER_NAMES).to_h { |name| [name, nil] }
    end
  end
end
