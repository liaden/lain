# frozen_string_literal: true

require "fileutils"

module Lain
  # The per-user lain-daemon, started on demand by whichever lain needs it
  # first and shared by every lain after. There is no service unit: a start
  # happens under a lock beside the socket, so callers racing to start one
  # end up connected to the same daemon. The socket path is the caller's, from
  # its own runtime dir, so 2 callers with different runtime dirs get 2 daemons.
  module Daemon
    # So a spec suite or a sandbox can run lain without starting a daemon.
    SWITCH = "LAIN_DAEMON"
    OFF = "off"

    START_BUDGET = 5.0
    STOP_BUDGET = 5.0
    WAIT = FileLock::Wait.new(patience: Float::INFINITY, interval: 0.02)
    UNTOLD = -> {}

    UNBUILT = "lain-daemon is not built at %<binary>s; run `bundle exec rake daemon:build`"
    SWITCHED_OFF = "the daemon is off: #{SWITCH}=#{OFF}".freeze
    PENDING = "the daemon at %<socket>s is from another launch and has %<runs>d live runs; " \
              "it restarts once they end"

    # The daemon was spawned and never answered.
    class Unstarted < Error; end

    # A daemon asked to stop that kept running.
    class Unstopped < Error; end

    # What a session holds when no daemon is there to register with.
    class Registration
      # Takes every message a registration answers and does nothing.
      class Null
        # @return [nil]
        def open(_task) = nil

        # @return [nil]
        def close = nil

        # @return [nil]
        def call(*) = nil

        # @return [nil]
        def on(*) = nil
      end
    end

    Absent = Data.define(:reason)

    # No daemon to talk to, and why.
    class Absent
      # @return [Registration::Null]
      def registration(...) = Registration::Null.new
    end

    # @param paths [Paths]
    # @return [String] the socket every lain with this runtime dir shares
    def self.socket(paths:) = File.join(paths.daemon_dir, "daemon.sock")

    # Must run inside an Async reactor, as {Core::Client} does.
    # @param paths [Paths] where the daemon directory is
    # @param env [Hash] where the off switch and the launch are read
    # @param launch [Launch, nil] how to start one, and what a running one must match; this
    #   checkout's {Launch.current} when nil, built only once the off switch is read
    # @param notes [#puts] told why there is no daemon, or that a restart waits on live runs
    # @return [Core::Client, Absent]
    # @raise [Unstarted] when a spawned daemon exits or stays silent past the budget
    def self.ensure(paths:, env: ENV, launch: nil, notes: Sink::Null.new)
      return absent(SWITCHED_OFF, notes) if env[SWITCH] == OFF

      launch ||= Launch.current(paths:, env:)
      return absent(format(UNBUILT, binary: launch.binary), notes) unless built?(launch)

      FileUtils.mkdir_p(paths.daemon_dir, mode: 0o700)
      FileLock.new(File.join(paths.daemon_dir, "start.lock"), label: "the daemon start").hold do
        attached = attach(launch.socket)
        attached && closing_on_error(attached) { kept?(attached, launch, notes) } ? attached : started(launch)
      end
    end

    # Must run inside an Async reactor.
    # @param paths [Paths]
    # @return [nil]
    # @raise [Unstopped] when it outlives the budget
    def self.stop(paths:)
      client = attach(socket(paths:))
      closing_on_error(client) { halt(client, socket(paths:)) } if client
      nil
    end

    def self.built?(launch) = File.file?(launch.binary) && File.executable?(launch.binary)

    def self.absent(reason, notes)
      notes.puts(reason)
      Absent.new(reason:)
    end

    def self.attach(socket)
      Core::Client.start(transport: Core::Transport::Unix.new(socket))
    rescue Core::Transport::Unix::Unreachable
      nil
    end

    def self.closing_on_error(client)
      yield
    rescue StandardError
      client.stop
      raise
    end

    # A daemon whose runs would die with it is kept until they end.
    def self.kept?(client, launch, notes)
      info = client.call("daemon.info")
      return true if info.fetch("launch_digest") == launch.digest

      runs = info.fetch("live_runs", 0)
      notes.puts(format(PENDING, socket: launch.socket, runs:)) if runs.positive?
      halt(client, launch.socket) if runs.zero?
      runs.positive?
    end

    def self.halt(client, socket)
      pid = client.call("ping").fetch("pid")
      client.stop
      Process.kill("TERM", pid)
      gone = WAIT.succeeded?(UNTOLD, deadline: STOP_BUDGET) { !File.exist?(socket) || !running?(pid) }
      raise Unstopped, "the daemon pid #{pid} at #{socket} did not stop in #{STOP_BUDGET}s" unless gone

      true
    rescue Errno::ESRCH
      true
    end

    def self.running?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    def self.started(launch)
      waiter = Process.detach(spawned(launch))
      client = nil
      WAIT.succeeded?(UNTOLD, deadline: START_BUDGET) { !waiter.alive? || (client = attach(launch.socket)) }
      client || raise(Unstarted, unstarted(launch, waiter))
    end

    # Its own session, so neither a Ctrl-C nor a closed terminal that ends the
    # starter reaches the daemon; nothing inherited but the launch's env. exec
    # only comes back by raising, and any other way out of the child would run
    # the parent's at_exit hooks in this copy of it.
    def self.spawned(launch)
      Process.fork do
        Process.setsid
        Process.exec(launch.env, *launch.argv, unsetenv_others: true, close_others: true, chdir: "/",
                                               in: File::NULL, out: File::NULL, err: File::NULL)
      ensure
        exit!(127)
      end
    end

    def self.unstarted(launch, waiter)
      how = waiter.alive? ? "did not answer in #{START_BUDGET}s" : "exited (#{waiter.value})"
      "lain-daemon #{how}; its trace is #{launch.trace}"
    end

    private_class_method :built?, :absent, :attach, :closing_on_error, :kept?, :halt, :running?, :started,
                         :spawned, :unstarted
  end
end
