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
    PENDING = "this chat uses the daemon another checkout started at %<socket>s, which has %<busy>s; " \
              "it restarts on this checkout's build once %<those>s"
    KEYLESS = "the daemon at %<socket>s lacks #{Launch::PROVIDER_KEY}, so runs it starts cannot reach anthropic " \
              "until it restarts; it has %<busy>s and restarts once %<those>s".freeze

    # The daemon was spawned and never answered.
    class Unstarted < Error; end

    # A daemon asked to stop that kept running.
    class Unstopped < Error; end

    # No daemon to talk to, and why.
    Absent = Data.define(:reason)

    # @param paths [Paths]
    # @return [String] the socket every lain with this runtime dir shares
    def self.socket(paths:) = File.join(paths.daemon_dir, "daemon.sock")

    # Must run inside an Async reactor, as {Core::Client} does.
    # @param paths [Paths] where the daemon directory is
    # @param env [Hash] where the off switch and the launch are read
    # @param launch [Launch, nil] how to start one, and what a running one must match; this
    #   checkout's {Launch.current} when nil, built only once the off switch is read
    # @param notes [#puts] told why there is no daemon, or that a restart waits on live runs
    # @param pushes [Async::Queue, nil] where the client hands what the daemon pushes; see {Core::Client.start}
    # @param replace [Boolean] false to take whatever daemon answers, starting one only when none does
    # @return [Core::Client, Absent]
    # @raise [Unstarted] when a spawned daemon exits or stays silent past the budget
    def self.ensure(paths:, env: ENV, launch: nil, notes: Sink::Null.new, pushes: nil, replace: true)
      return absent(SWITCHED_OFF, notes) if env[SWITCH] == OFF

      launch ||= Launch.current(paths:, env:)
      return absent(format(UNBUILT, binary: launch.binary), notes) unless built?(launch)

      FileUtils.mkdir_p(paths.daemon_dir, mode: 0o700)
      FileLock.new(File.join(paths.daemon_dir, "start.lock"), label: "the daemon start").hold do
        attached = attach(launch.socket, pushes)
        attached && usable?(attached, launch, notes, replace) ? attached : started(launch, pushes)
      end
    end

    # Never starts a daemon, for the callers that only read one.
    # Must run inside an Async reactor.
    # @param paths [Paths]
    # @param env [Hash] where the off switch and the launch are read
    # @param launch [Launch, nil] this checkout's {Launch.current} when nil
    # @return [Core::Client, nil] nil when no daemon answers
    # @raise [Error] when the daemon is off or its binary is not built
    def self.attached(paths:, env: ENV, launch: nil)
      raise Error, SWITCHED_OFF if env[SWITCH] == OFF

      launch ||= Launch.current(paths:, env:)
      raise Error, format(UNBUILT, binary: launch.binary) unless built?(launch)

      attach(launch.socket)
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

    def self.attach(socket, pushes = nil)
      Core::Client.start(transport: Core::Transport::Unix.new(socket), pushes:)
    rescue Core::Transport::Unix::Unreachable
      nil
    end

    def self.closing_on_error(client)
      yield
    rescue StandardError
      client.stop
      raise
    end

    def self.usable?(client, launch, notes, replace)
      !replace || closing_on_error(client) { kept?(client, launch, notes) }
    end

    # A daemon with live runs, which a replacement could no longer list or
    # stop, or with chats that would have to register again, is kept until
    # they end. Two checkouts sharing a runtime dir would otherwise replace
    # each other's daemon on every start.
    def self.kept?(client, launch, notes)
      info = client.call("daemon.info")
      return true if info.fetch("launch_digest") == launch.digest

      runs = info.fetch("live_runs", 0)
      chats = client.call("session.list").size
      busy = runs.positive? || chats.positive?
      busy ? notes.puts(pending(launch, info, chats:, runs:)) : halt(client, launch.socket)
      busy
    end

    def self.pending(launch, info, chats:, runs:)
      held = { "chat" => chats, "live run" => runs }.select { |_, count| count.positive? }
      busy = held.map { |noun, count| "#{count} #{noun}#{"s" unless count == 1}" }.join(" and ")
      format(keyless?(launch, info) ? KEYLESS : PENDING,
             socket: launch.socket, busy:, those: held.values.sum == 1 ? "that ends" : "those end")
    end

    # The daemon is this launch's in all but the provider key it was started without: a launch
    # with no key has the same digest without one, which already differed from the daemon's.
    def self.keyless?(launch, info)
      launch.with(env: launch.env.except(Launch::PROVIDER_KEY)).digest == info.fetch("launch_digest")
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

    def self.started(launch, pushes)
      waiter = Process.detach(spawned(launch))
      client = nil
      WAIT.succeeded?(UNTOLD, deadline: START_BUDGET) { !waiter.alive? || (client = attach(launch.socket, pushes)) }
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

    private_class_method :built?, :absent, :attach, :closing_on_error, :usable?, :kept?, :pending, :keyless?, :halt,
                         :running?, :started, :spawned, :unstarted
  end
end
