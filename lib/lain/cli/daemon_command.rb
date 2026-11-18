# frozen_string_literal: true

require "thor"

module Lain
  module CLI
    # `lain daemon status|runs|ensure|restart|stop|run|herdr-sync`. The read verbs only attach,
    # because a status that starts a daemon leaves one behind that nobody asked for;
    # `ensure`, `restart` and `run` are the verbs that start one. `herdr-sync` is the daemon's own
    # call, made as runs start, end, park and unpark, and so is the hidden `spawner`, which neither
    # starts nor attaches one.
    class DaemonCommand < ::Thor
      include Exe::Boundary

      namespace "daemon"

      # Kinds a human starts; the review poll belongs to the daemon's own timer.
      KINDS = %w[epic chores].freeze
      USAGE = "lain daemon run epic SLUG | lain daemon run chores"
      NONE = "no daemon is running"
      LIVE = "the daemon has live runs: %<ids>s; `lain daemon restart --force` restarts it anyway"

      # What a human reads for the runs `run.list` answers, which `status` and `runs` both show.
      module RunLines
        # @param runs [Array<Hash>] run.list
        # @return [Array<String>] one line per run
        def self.call(runs)
          runs.map do |run|
            what = [run.fetch("kind"), run["slug"]].compact.join(" ")
            state = run.fetch("status").nil? ? "running" : "exited #{run.fetch("status")}"
            "#{run.fetch("id")}  #{what}  #{state}  pid #{run.fetch("pid")}  #{run.fetch("log")}"
          end
        end
      end

      # The runs token herdr shows on the `lain` workspace. The review poll is left out: it is the
      # daemon's own timer and has the `reviews` workspace.
      module RunsToken
        # @param runs [Array<Hash>] run.list
        # @return [String] empty when no run is live
        def self.call(runs)
          runs.select { |run| run.fetch("status").nil? && run.fetch("kind") != "review-poll" }.map do |run|
            "#{[run.fetch("kind"), run["slug"]].compact.join(" ")}: #{run["blocked"] ? "blocked" : "working"}"
          end.join("; ")
        end
      end

      # One daemon answer as the lines a human reads.
      class Report
        # @param info [Hash] daemon.info
        # @param pid [Integer] the daemon's process
        # @param uptime [String] how long it has run, as ps says it
        # @param sessions [Array<Hash>] session.list
        # @param runs [Array<Hash>] run.list
        def initialize(info:, pid:, uptime:, sessions:, runs:)
          @info = info
          @pid = pid
          @uptime = uptime
          @sessions = sessions
          @runs = runs
        end

        # @return [String]
        def to_s
          ["pid: #{@pid}", "uptime: #{@uptime}", "build: #{@info.fetch("build_id")}",
           "relay: #{@info.fetch("relay")}", *session_lines, *RunLines.call(@runs).map { "run #{_1}" }].join("\n")
        end

        private

        def session_lines
          @sessions.map { |s| "session #{s.fetch("session_id")} pid #{s.fetch("pid")} #{s.fetch("root")}" }
        end
      end

      # The daemon's own notes (a restart that waits on live runs, a missing provider key), said
      # to the human instead of dropped.
      Notes = Data.define(:command) do
        def puts(text) = command.say(text)
      end

      def self.exit_on_failure? = true

      map "run" => :start_run

      desc "status", "The daemon's pid, uptime, build and relay, its sessions and its runs"
      def status = render { attached(NONE) { |client| report(client).to_s } }

      desc "runs", "The runs the daemon supervises"
      def runs = render { attached(NONE) { |client| runs_text(client.call("run.list")) } }

      desc "ensure", "Start the daemon if none runs, or replace one this checkout's build has outdated"
      def ensure = render { talk(replace: true) { |client| "daemon pid #{client.call("ping").fetch("pid")}" } }

      desc "restart", "Stop the daemon and start it again; refuses while a run is live"
      method_option :force, type: :boolean, default: false,
                            desc: "Restart even with live runs, which keep going unlisted"
      def restart
        render do
          live = attached([]) { |client| live_runs(client) }
          refuse(live) unless live.empty? || options[:force]

          Sync { ::Lain::Daemon.stop(paths: Paths.new) }
          talk(replace: true) do |client|
            [*left_running(live), "daemon restarted, pid #{client.call("ping").fetch("pid")}"].join("\n")
          end
        end
      end

      desc "herdr-sync", "Show the live runs on the lain herdr workspace; the daemon runs it as runs change"
      def herdr_sync
        render(newline: false) do
          attached("") do |client|
            show_runs(RunsToken.call(client.call("run.list")))
            ""
          end
        end
      end

      desc "spawner", "Fork headless runs from this warmed process, as the daemon asks on stdin", hide: true
      def spawner
        # LainCLI is exe/lain's, the only entry this hidden command is reached through.
        ::Lain::Daemon::Spawner.on_stdin(starter: ->(argv) { ::LainCLI.start(argv) }).call
      end

      desc "stop RUN", "End a run: TERM its process group, KILL after its shutdown grace"
      def stop(id)
        render do
          attached(nil) do |client|
            ended = client.call("run.stop", [{ "id" => id }])
            "run #{id} #{ended.fetch("status").nil? ? "still running" : "exited #{ended.fetch("status")}"}"
          end
        end
      end

      desc "run epic SLUG | chores", "Start a run in the current project; it outlives this terminal"
      def start_run(kind = nil, slug = nil)
        render do
          raise Thor::Error, USAGE unless started_by_hand?(kind, slug)

          talk do |client|
            "#{client.call("run.start", [run_request(kind, slug)]).fetch("id")} started; `lain daemon runs` shows it"
          end
        end
      end

      private

      def show_runs(text)
        workspaces = ::Lain::Herdr::Workspaces.new(source: "lain-daemon")
        if text.empty?
          workspaces.clear_token(label: "lain", name: "runs")
        else
          workspaces.token(label: "lain", name: "runs", value: text)
        end
      end

      def started_by_hand?(kind, slug) = KINDS.include?(kind) && (kind == "epic") == !slug.nil?

      def run_request(kind, slug)
        { "kind" => kind, "root" => ::Lain::Project::Resolver.default_project.root,
          "args" => slug ? { "slug" => slug } : {} }
      end

      def report(client)
        pid = client.call("ping").fetch("pid")
        Report.new(info: client.call("daemon.info"), pid:, uptime: uptime(pid),
                   sessions: client.call("session.list"), runs: client.call("run.list"))
      end

      # ps rather than a daemon field: it reads the same on Linux and macOS.
      def uptime(pid)
        out = Shell::Out.new("ps", "-o", "etime=", "-p", pid.to_s).run_command
        Shell::Out.ok?(out) ? out.stdout.strip : "unknown"
      end

      def refuse(live) = raise(Lain::Error, format(LIVE, ids: live.map { |run| run.fetch("id") }.join(", ")))

      def runs_text(runs) = runs.empty? ? "no runs" : RunLines.call(runs).join("\n")

      def live_runs(client) = client.call("run.list").select { |run| run.fetch("status").nil? }

      # Runs outlive a stopped daemon, so a forced restart leaves them where the new daemon cannot list them.
      def left_running(live)
        return [] if live.empty?

        ["#{live.size} #{live.size == 1 ? "run keeps" : "runs keep"} going unlisted:",
         *live.map { |run| "  #{run.fetch("id")}  pid #{run.fetch("pid")}" }]
      end

      # Never starts a daemon: a read has no business leaving one behind. With nothing to attach to,
      # the block's answer is `none`, and a nil `none` is a refusal.
      def attached(none)
        Sync do
          client = ::Lain::Daemon.attached(paths: Paths.new, env: ENV)
          raise Lain::Error, NONE unless client || !none.nil?

          client ? serving(client) { yield client } : none
        end
      end

      def serving(client)
        yield
      ensure
        client.stop
      end

      # A replace of a daemon this build outdated waits on live runs and chats, so only the
      # verbs that ask for one pass `replace: true`.
      def talk(replace: false)
        Sync do
          client = ::Lain::Daemon.ensure(paths: Paths.new, env: ENV, replace:, notes: Notes.new(self))
          raise Lain::Error, client.reason if client.is_a?(::Lain::Daemon::Absent)

          serving(client) { yield client }
        end
      end
    end
  end
end
