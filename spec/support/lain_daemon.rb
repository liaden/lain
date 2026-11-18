# frozen_string_literal: true

require "async"

# No example reaches a daemon by accident: the suite sets the off switch, so
# {Lain::Daemon.ensure} answers Absent, and so does every `lain` a spec spawns,
# since the switch is inherited. An example tagged :daemon lifts it for its own
# run and gets a runtime dir of its own, whose daemon is stopped afterwards.
module LainDaemon
  SWITCH = "LAIN_DAEMON"
  OFF = "off"
  ENV[SWITCH] = OFF
  REAP_BUDGET = 5

  # A daemon outliving its example is a leak the next example cannot see.
  class Leaked < StandardError; end

  # @return [Hash] the environment this example's lain runs with
  attr_reader :daemon_env

  # @return [Lain::Paths] whose runtime dir is this example's alone
  attr_reader :daemon_paths

  # @return [Lain::Daemon::Launch] the launch ensure uses for this example's paths
  def daemon_launch = Lain::Daemon::Launch.current(paths: daemon_paths, env: daemon_env)

  # @param paths [Lain::Paths]
  # @return [Integer, nil] the pid of the daemon answering there
  def self.pid_at(paths)
    client = Lain::Core::Client.start(transport: Lain::Core::Transport::Unix.new(Lain::Daemon.socket(paths:)))
    client.call("ping").fetch("pid").tap { client.stop }
  rescue Lain::Core::Transport::Unix::Unreachable
    nil
  end

  # @param paths [Lain::Paths]
  # @return [nil]
  # @raise [Leaked] when the daemon there is still running once stopped
  def self.reap(paths)
    pid = Sync { pid_at(paths) }
    Sync { Lain::Daemon.stop(paths:) }
    raise Leaked, "the daemon pid #{pid} outlived its example" if pid && running_after_budget?(pid)
  end

  def self.running_after_budget?(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + REAP_BUDGET
    sleep 0.02 while running?(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    running?(pid)
  end

  # Dir.mktmpdir names carry the creating process's pid, so this matches only
  # the daemons this suite process started, never another worker's.
  # @return [Array<String>] each such daemon's pid and argv
  def self.strays
    mine = "-#{Process.pid}-"
    IO.popen(["ps", "-ax", "-o", "pid=,args="], &:read).lines.map(&:strip)
      .select { |line| line.include?("lain-daemon") && line.include?("--socket") && line.include?(mine) }
  end

  def self.running?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end

RSpec.configure do |config|
  config.include LainDaemon, :daemon

  config.after(:suite) do
    strays = LainDaemon.strays
    raise LainDaemon::Leaked, "lain-daemons outlived the suite:\n#{strays.join("\n")}" unless strays.empty?
  end

  config.before(:each, :daemon) do
    unless File.executable?(daemon_launch.binary)
      absent_binary("lain-daemon not built at #{daemon_launch.binary} -- run `bundle exec rake daemon:build`")
    end
  end

  config.around(:each, :daemon) do |example|
    socket_tmpdir("lain-daemon") do |dir|
      @daemon_env = ENV.to_h.merge("XDG_RUNTIME_DIR" => dir).except(LainDaemon::SWITCH)
      @daemon_paths = Lain::Paths.new(env: SpecHome.env(@daemon_env))
      begin
        ENV.delete(LainDaemon::SWITCH)
        example.run
      ensure
        ENV[LainDaemon::SWITCH] = LainDaemon::OFF
        LainDaemon.reap(@daemon_paths)
      end
    end
  end
end
