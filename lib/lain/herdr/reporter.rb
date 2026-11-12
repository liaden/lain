# frozen_string_literal: true

require "json"

module Lain
  module Herdr
    # Tells herdr the chat's state and how to resume it, the way herdr's own Claude Code integration
    # does: `pane report-agent` on each change of the rollup, `pane release-agent` when the target
    # moves or the chat closes. Only a pane the resolver proves is lain's is ever named.
    #
    # Every call runs on 1 worker thread, in order, so a slow or missing herdr costs the chat nothing
    # but a note.
    class Reporter
      AGENT = Herdr::AGENT

      TIMEOUT = 2

      # herdr 0.9.5 has no done; its idle shows as done until the human focuses the pane.
      STATES = { blocked: "blocked", working: "working", done: "idle", idle: "idle" }.freeze

      # herdr refuses a resume command past these, or with an apostrophe in any word.
      RESUME_BYTES = 8 * 1024

      RESUME_WORDS = 64

      # Used until the chat's terminal hands over its own mask ({#mask_with}): it knows detected regions
      # and the process's secret-named environment values, but not a committed .env or a passed
      # connection string, which only the chat's secret source holds.
      MASK = ->(text) { Sensitivity::TextMask.text(text, secrets: Sensitivity::Secrets::Source::DEFAULT) }

      Report = Data.define(:state, :what)

      # A chat with no herdr to tell drops every message, but its commands still mask through {MASK}.
      Null = Data.define do
        def mask = MASK
        def call(_change) = nil
        def to_proc = method(:call).to_proc
        def metadata(_token, _value) = nil
        def mask_with(_mask) = self
        def release = nil
      end

      # What `lain up` recorded on the tmux session of the cockpit pane this chat runs in, asked only when
      # a report needs it.
      class CockpitSession
        # The words after `lain` that bring this cockpit back, as JSON; set by `lain up` when it creates the session.
        OPTION = "@lain_up_command"

        # @param env [#[]] the chat's environment
        # @param shell_out [#call] `Shell::Out.new`'s shape
        def initialize(env:, shell_out: Shell::Out.public_method(:new))
          @env = env
          @shell_out = shell_out
        end

        # @return [Array<String>] `lain up`'s own words up to and including `--`, empty when tmux does not
        #   answer or the session holds no usable command
        def to_a = @to_a ||= words

        private

        def words
          parsed = JSON.parse(ask)
          parsed.is_a?(Array) && parsed.all?(String) ? parsed : []
        rescue JSON::ParserError
          []
        end

        def ask
          pane = @env["TMUX_PANE"].to_s
          return "" if pane.empty?

          answer = @shell_out.call("tmux", "display-message", "-p", "-t", pane, "\#{#{OPTION}}",
                                   environment: { "TMUX" => @env["TMUX"] }, timeout: TIMEOUT).tap(&:run_command)
          Shell::Out.ok?(answer) ? answer.stdout.strip : ""
        rescue SystemCallError, Shell::Out::Timeout
          ""
        end
      end

      # @param resolver [#current] answers the {Target} lain may report to, or nil
      # @param session [#journal_path] the chat's record, read at each report since a promoted aside
      #   moves its file; a nil path leaves out the resume command
      # @param up_command [#to_a] the words after `lain` that reopen this chat's cockpit; empty leaves out
      #   a cockpit's resume command
      # @param child_argv [CLI::ChildArgv] builds a plain chat's resume command from the live run
      # @param agent [String] the agent name herdr shows
      # @param resume [Boolean] false never sends a resume command
      # @param shell_out_factory [#call] `Shell::Out.new`'s shape
      # @param notes [#puts] told once each time reporting starts failing
      # @param mask [#call] takes a wait's summary and answers it with secrets masked; see {#mask_with}
      # @param background [#call] starts the worker off the caller's stack
      def initialize(resolver:, session:, up_command: [], child_argv: CLI::ChildArgv.bare, agent: AGENT, resume: true,
                     shell_out_factory: Shell::Out.public_method(:new), notes: Sink::Null.new, mask: MASK,
                     background: Thread.public_method(:new))
        @resolver = resolver
        @session = session
        @up_command = up_command
        @child_argv = child_argv
        @agent = agent
        @resume = resume
        @shell_out_factory = shell_out_factory
        @notes = notes
        @mask = mask
        @background = background
        @jobs = Thread::Queue.new
        @start = Mutex.new
        @seq = 0
      end

      # @return [#call] takes text and answers it with secrets masked
      attr_reader :mask

      # @param mask [#call] the chat's own, once its secret source exists
      # @return [self]
      def mask_with(mask)
        @mask = mask
        self
      end

      # @return [Proc] for `tracker.on_change(&reporter)`
      def to_proc = method(:call).to_proc

      # @param change [AgentStates::Tracker::Change]
      # @return [nil]
      def call(change)
        enqueue([:report, change])
        nil
      end

      # @param token [String] the metadata token's name
      # @param value [String, nil] nil clears the token
      # @return [nil]
      def metadata(token, value)
        enqueue([:metadata, value.nil? ? ["--clear-token", token] : ["--token", "#{token}=#{plain(value)}"]])
        nil
      end

      # Waits for the queued reports, then gives the pane back. Later changes are dropped.
      #
      # @return [nil]
      def release
        worker = @start.synchronize do
          released_before = @closed
          @closed = true
          @worker unless released_before
        end
        return unless worker

        @jobs << [:release]
        @jobs.close
        worker.kill unless worker.join((TIMEOUT * 3) + 1)
        nil
      end

      # The file is named by its basename, which `--resume` resolves under the project the command pins,
      # so the command works from any directory.
      #
      # @param target [Target] the pane the words are for
      # @return [Array<String>] a command line that resumes this chat, empty when there is none to give
      def resume_words(target) = words_for(target, @session.journal_path)

      private

      def enqueue(job)
        @start.synchronize do
          return if @closed

          @worker ||= @background.call { work }
          @jobs << job
        end
      end

      def work
        while (job = @jobs.pop)
          run(*job)
        end
      end

      def run(kind, argument = nil)
        case kind
        when :report then reported(argument)
        when :metadata then described(argument)
        when :release then released
        end
      rescue StandardError => e
        note("herdr: reporting failed in lain (#{e.class}: #{@mask.call(e.message.to_s)}); " \
             "lain retries on the next change")
      end

      def reported(change)
        report = next_report(change)
        target = @resolver.current
        moved = target&.with(via: nil) != @target&.with(via: nil)
        released if moved
        send_report(target, report) if target && (moved || report != @report)
        @report = report
      end

      def next_report(change)
        what = change.agent.state == :blocked ? change.agent.what : @report&.what
        Report.new(state: STATES.fetch(change.rollup), what: change.rollup == :blocked ? what : nil)
      end

      def send_report(target, report)
        @target = target
        herdr(target, "pane", "report-agent", target.pane, *identity, "--state", report.state, *seq,
              *message(report.what), *resume_command(target))
      end

      def described(token_flags)
        target = @target || @resolver.current
        herdr(target, "pane", "report-metadata", target.pane, *identity, *token_flags, *seq) if target
      end

      def released
        target = @target
        @target = nil
        herdr(target, "pane", "release-agent", target.pane, *identity, *seq) if target
      end

      def identity = ["--source", SOURCE, "--agent", @agent]

      # herdr drops a report whose seq is not above the last, across lain restarts too.
      def seq
        @seq = [@seq + 1, Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)].max
        ["--seq", @seq.to_s]
      end

      def message(what)
        what.to_s.empty? ? [] : ["--message", plain(what)]
      end

      def plain(text) = Frontend::TTY::Notifier.plain(text, mask: @mask)

      def resume_command(target)
        path = @session.journal_path
        return [] unless @resume && path

        words = words_for(target, path)
        reason = refusal(words)
        reason ? left_out(reason) : ["--", *words]
      end

      def words_for(target, path)
        return [] unless @resume && path

        name = File.basename(path)
        return ["lain", *@child_argv.chat("--resume", name)] if target.via == :env

        stored = @up_command.to_a
        stored.empty? ? [] : ["lain", *stored, "--resume", name]
      end

      # A word is checked whole rather than masked: herdr keeps the command in a file and types it into
      # the restored pane's shell, so a credential in it would outlive the chat.
      def refusal(words)
        if words.empty? then "the cockpit stored no command to restart it with"
        elsif words.size > RESUME_WORDS then "its command is over #{RESUME_WORDS} words"
        elsif words.sum(&:bytesize) > RESUME_BYTES then "its command is over #{RESUME_BYTES} bytes"
        elsif words.any? { _1.include?("'") } then "a word of its command holds an apostrophe"
        elsif words.any? { CLI::ChildArgv.mask(_1) != _1 } then "a word of its command carries a URL credential"
        end
      end

      def left_out(reason)
        unless @told
          @notes.puts("herdr: no resume command is stored for this chat (#{reason}); herdr cannot restart it")
        end
        @told = true
        []
      end

      def herdr(target, *argv)
        answer = @shell_out_factory.call(target.bin, *argv, environment: target.environment, timeout: TIMEOUT)
                                   .tap(&:run_command)
        Shell::Out.ok?(answer) ? recovered : failed(target)
      rescue SystemCallError, Shell::Out::Timeout
        failed(target)
      end

      def recovered = @failing = false

      def failed(target) = note("herdr: reporting to pane #{target.pane} failed; lain retries on the next change")

      def note(line)
        @notes.puts(line) unless @failing
        @failing = true
      end
    end
  end
end
