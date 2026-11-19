# frozen_string_literal: true

require "async"
require "fileutils"
require "msgpack"
require "socket"

RSpec.describe Lain::Daemon do
  def ping_pid(client) = client.call("ping").fetch("pid")

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  describe ".socket" do
    it "is daemon.sock in the daemon directory of the runtime dir" do
      paths = Lain::Paths.new(env: SpecHome.env({ "XDG_RUNTIME_DIR" => "/run/user/7" }))

      expect(described_class.socket(paths:)).to eq("/run/user/7/lain/daemon/daemon.sock")
    end
  end

  describe "an unbuilt binary" do
    it "answers Absent, telling the notes how to build it, and Absent registers nothing" do
      Dir.mktmpdir("unbuilt-daemon") do |dir|
        paths = Lain::Paths.new(env: SpecHome.env({ "XDG_RUNTIME_DIR" => dir }))
        launch = Lain::Daemon::Launch.current(paths:).with(binary: File.join(dir, "missing"))
        notes = StringIO.new

        absent = described_class.ensure(paths:, launch:, notes:, env: {})

        expect(absent).to be_a(Lain::Daemon::Absent)
        expect(absent.reason).to include("rake daemon:build")
        expect(notes.string).to include("rake daemon:build")
      end
    end
  end

  describe "the env it is given" do
    it "is where it looks for the binary" do
      socket_tmpdir("env-daemon") do |dir|
        paths = Lain::Paths.new(env: SpecHome.env({ "XDG_RUNTIME_DIR" => dir }))
        env = { "CARGO_TARGET_DIR" => File.join(dir, "no-build") }

        result = Sync { described_class.ensure(paths:, env:).tap { |answer| answer.stop if answer.respond_to?(:stop) } }

        expect(result).to be_a(Lain::Daemon::Absent)
        expect(result.reason).to include(File.join(dir, "no-build"))
      ensure
        Sync { described_class.stop(paths:) }
      end
    end
  end

  describe "a binary path that is a directory" do
    it "answers Absent, and starts nothing that could write to this process's streams" do
      socket_tmpdir("dir-daemon") do |dir|
        paths = Lain::Paths.new(env: SpecHome.env({ "XDG_RUNTIME_DIR" => dir }))
        launch = Lain::Daemon::Launch.current(paths:).with(binary: dir)
        result = nil

        expect { result = Sync { described_class.ensure(paths:, launch:, env: {}) } }
          .not_to output.to_stderr_from_any_process
        expect(result).to be_a(Lain::Daemon::Absent)
      end
    end
  end

  describe "the off switch" do
    it "is read before the binary is hashed" do
      Dir.mktmpdir("off-hash") do |dir|
        FileUtils.mkdir_p(File.join(dir, "release"))
        File.write(File.join(dir, "release", "lain-daemon"), "built")
        allow(Digest::SHA256).to receive(:file).and_call_original

        described_class.ensure(paths: Lain::Paths.new(env: SpecHome.env({ "XDG_RUNTIME_DIR" => dir })),
                               env: { "LAIN_DAEMON" => "off", "CARGO_TARGET_DIR" => dir })

        expect(Digest::SHA256).not_to have_received(:file)
      end
    end
  end

  describe ".attached" do
    it "refuses, naming rake daemon:build, when the binary is not built" do
      Dir.mktmpdir("attached-unbuilt") do |dir|
        paths = Lain::Paths.new(env: SpecHome.env({ "XDG_RUNTIME_DIR" => dir }))
        env = { "CARGO_TARGET_DIR" => dir }

        expect { Sync { described_class.attached(paths:, env:) } }.to raise_error(Lain::Error, /rake daemon:build/)
      end
    end

    it "refuses when the off switch is set, before it reads the binary" do
      Dir.mktmpdir("attached-off") do |dir|
        paths = Lain::Paths.new(env: SpecHome.env({ "XDG_RUNTIME_DIR" => dir }))

        expect { Sync { described_class.attached(paths:, env: { "LAIN_DAEMON" => "off" }) } }
          .to raise_error(Lain::Error, /off/)
      end
    end
  end

  describe "in an example that does not opt in" do
    it "answers Absent without making the runtime dir" do
      Dir.mktmpdir("off-daemon") do |dir|
        paths = Lain::Paths.new(env: SpecHome.env({ "XDG_RUNTIME_DIR" => dir }))

        expect(described_class.ensure(paths:)).to be_a(Lain::Daemon::Absent)
        expect(Dir.children(dir)).to be_empty
      end
    end
  end

  # A Ruby stand-in for a daemon from another launch with a run still going: it answers ping with
  # the pid of a process it does not own, so a wrongful stop would be seen, never suffered.
  describe "a daemon from another launch with live runs" do
    around do |example|
      socket_tmpdir("busy-daemon") do |dir|
        @paths = Lain::Paths.new(env: SpecHome.env({ "XDG_RUNTIME_DIR" => dir }))
        FileUtils.mkdir_p(File.dirname(described_class.socket(paths: @paths)), mode: 0o700)
        @stand_in = Process.spawn("sh", "-c", 'trap "" TERM; exec sleep 60')
        @live_runs = 1
        @sessions = []
        @refuse_info = false
        @push_on_info = false
        @info = { "build_digest" => "another", "settings_digest" => "other settings" }
        @provider_key = false
        @hangups = Thread::Queue.new
        @server = UNIXServer.new(described_class.socket(paths: @paths))
        @serving = Thread.new { loop { answer(@server.accept) } }
        example.run
      ensure
        @serving&.kill
        @server&.close
        Process.kill("KILL", @stand_in)
        Process.wait(@stand_in)
      end
    end

    def answer(connection)
      Thread.new do
        MessagePack::Unpacker.new(connection).each do |_kind, msgid, method, _params|
          connection.write(MessagePack.pack([Lain::Core::Client::RESPONSE, msgid, *reply(method)]))
          push = @push_on_info && method == "daemon.info"
          connection.write(MessagePack.pack([Lain::Core::Client::PUSH, "offer", [method]])) if push
        end
        @hangups << :hangup
      rescue IOError, SystemCallError
        connection.close
      end
    end

    def reply(method)
      return ["refused", nil] if method == "daemon.info" && @refuse_info

      [nil, { "ping" => { "version" => Lain::Core::Client::PROTOCOL_VERSION, "pid" => @stand_in },
              "daemon.info" => @info.merge("live_runs" => @live_runs, "provider_key" => @provider_key),
              "session.list" => @sessions }.fetch(method)]
    end

    it "hangs up on it when its answer about its launch is refused" do
      @refuse_info = true
      launch = Lain::Daemon::Launch.current(paths: @paths).with(binary: RbConfig.ruby)

      expect { Sync { described_class.ensure(paths: @paths, launch:, env: {}) } }
        .to raise_error(Lain::Core::Client::Refused)
      expect(@hangups.pop(timeout: 2)).to eq(:hangup)
    end

    it "keeps it, and says once that a restart is pending" do
      launch = Lain::Daemon::Launch.current(paths: @paths).with(binary: RbConfig.ruby)
      notes = StringIO.new

      pid = Sync do
        client = described_class.ensure(paths: @paths, launch:, notes:, env: {})
        ping_pid(client).tap { client.stop }
      end

      expect(pid).to eq(@stand_in)
      expect(alive?(@stand_in)).to be(true)
      expect(notes.string.lines.grep(/restart/).size).to eq(1)
    end

    it "keeps it while a chat is registered there, and says once that a restart is pending" do
      @live_runs = 0
      @sessions = [{ "session_id" => "elsewhere" }]
      launch = Lain::Daemon::Launch.current(paths: @paths).with(binary: RbConfig.ruby)
      notes = StringIO.new

      pid = Sync do
        client = described_class.ensure(paths: @paths, launch:, notes:, env: {})
        ping_pid(client).tap { client.stop }
      end

      expect(pid).to eq(@stand_in)
      expect(notes.string.lines.grep(/restart/).size).to eq(1)
    end

    def pending_note
      launch = Lain::Daemon::Launch.current(paths: @paths).with(binary: RbConfig.ruby)
      notes = StringIO.new
      Sync { described_class.ensure(paths: @paths, launch:, notes:, env: {}).stop }
      notes.string
    end

    it "says in the singular that this chat uses another checkout's daemon until its 1 chat ends" do
      @live_runs = 0
      @sessions = [{ "session_id" => "elsewhere" }]

      expect(pending_note).to eq(
        "this chat uses the daemon another checkout started at #{described_class.socket(paths: @paths)}, " \
        "which has 1 chat; it restarts on this checkout's build once that ends\n"
      )
    end

    it "counts several chats and runs in the plural" do
      @live_runs = 3
      @sessions = [{ "session_id" => "a" }, { "session_id" => "b" }]

      expect(pending_note).to eq(
        "this chat uses the daemon another checkout started at #{described_class.socket(paths: @paths)}, " \
        "which has 2 chats and 3 live runs; it restarts on this checkout's build once those end\n"
      )
    end

    def keyed(launch) = launch.with(env: launch.env.merge(Lain::Daemon::Launch::PROVIDER_KEY => "sk-test"))

    it "says a kept daemon lacks the provider key when the key is all that differs" do
      keyless = Lain::Daemon::Launch.current(paths: @paths, env: {}).with(binary: RbConfig.ruby)
      @info = { "build_digest" => keyless.build_digest, "settings_digest" => keyless.settings_digest }
      notes = StringIO.new
      Sync { described_class.ensure(paths: @paths, launch: keyed(keyless), notes:, env: {}).stop }

      expect(notes.string).to eq(
        "the daemon at #{described_class.socket(paths: @paths)} lacks ANTHROPIC_API_KEY, so runs it starts " \
        "cannot reach anthropic until it restarts; it has 1 live run and restarts once that ends\n"
      )
    end

    it "says it is another checkout's when more than the key differs" do
      keyless = Lain::Daemon::Launch.current(paths: @paths, env: {}).with(binary: RbConfig.ruby)
      notes = StringIO.new
      Sync { described_class.ensure(paths: @paths, launch: keyed(keyless), notes:, env: {}).stop }

      expect(notes.string).to start_with("this chat uses the daemon another checkout started at")
    end

    it "attaches to an idle one without replacing it when told not to replace" do
      @live_runs = 0
      launch = Lain::Daemon::Launch.current(paths: @paths).with(binary: RbConfig.ruby)

      pid = Sync do
        client = described_class.ensure(paths: @paths, launch:, replace: false, env: {})
        ping_pid(client).tap { client.stop }
      end

      expect(pid).to eq(@stand_in)
    end

    it "hands what it pushes to the queue the caller gave" do
      @push_on_info = true
      launch = Lain::Daemon::Launch.current(paths: @paths).with(binary: RbConfig.ruby)
      pushes = Async::Queue.new

      pushed = Sync do
        client = described_class.ensure(paths: @paths, launch:, pushes:, env: {})
        pushes.dequeue.tap { client.stop }
      end

      expect(pushed).to eq(["offer", ["daemon.info"]])
    end

    def relayed(launch)
      launch.with(settings: { "relay" => ["--relay", "127.0.0.1:7820"], "devices file" => ["--devices-file", "/d"],
                              "review poll" => ["--poll-every", "300"] })
    end

    def kept_note(launch)
      notes = StringIO.new
      pid = Sync do
        client = described_class.ensure(paths: @paths, launch:, notes:, env: {})
        ping_pid(client).tap { client.stop }
      end
      [pid, notes.string]
    end

    it "keeps an idle one of this build whose settings differ, and says once which and how to apply them" do
      @live_runs = 0
      launch = Lain::Daemon::Launch.current(paths: @paths, env: {}).with(binary: RbConfig.ruby)
      started = relayed(launch)
      @info = { "build_digest" => started.build_digest, "settings_digest" => started.settings_digest }

      pid, note = kept_note(launch)

      expect([pid, alive?(@stand_in)]).to eq([@stand_in, true])
      expect(note).to eq(
        "the daemon at #{described_class.socket(paths: @paths)} keeps the relay, devices file, review poll it " \
        "started with, which this chat would start differently; `lain daemon restart` applies them\n"
      )
    end

    # Its runs dir comes from the chat's XDG_STATE_HOME, which 2 shells on 1 runtime dir can set apart.
    it "keeps an idle one started under another state home, and names the runs dir" do
      @live_runs = 0
      launch = Lain::Daemon::Launch.current(paths: @paths, env: {}).with(binary: RbConfig.ruby)
      started = launch.with(runs: "/elsewhere/state/lain/daemon/runs")
      @info = { "build_digest" => started.build_digest, "settings_digest" => started.settings_digest }

      pid, note = kept_note(launch)

      expect([pid, alive?(@stand_in)]).to eq([@stand_in, true])
      expect(note).to include("keeps the runs dir it started with")
    end

    it "keeps an idle one of this build whose settings digest it cannot read, and names its settings" do
      @live_runs = 0
      launch = Lain::Daemon::Launch.current(paths: @paths, env: {}).with(binary: RbConfig.ruby)
      @info = { "build_digest" => launch.build_digest, "settings_digest" => "abc,def" }

      pid, note = kept_note(launch)

      expect([pid, alive?(@stand_in)]).to eq([@stand_in, true])
      expect(note).to include("keeps the ntfy topic, runs dir it started with")
    end

    it "keeps an idle one of this build and the same settings without a word" do
      @live_runs = 0
      launch = Lain::Daemon::Launch.current(paths: @paths, env: {}).with(binary: RbConfig.ruby)
      @info = { "build_digest" => launch.build_digest, "settings_digest" => launch.settings_digest }

      expect(kept_note(launch)).to eq([@stand_in, ""])
    end

    it "keeps an idle one of another build when the user's config cannot be read, and names the error" do
      @live_runs = 0
      Dir.mktmpdir("unread-home") do |home|
        paths = Lain::Paths.new(env: { "HOME" => home, "XDG_RUNTIME_DIR" => File.dirname(@paths.runtime_dir) })
        FileUtils.mkdir_p(File.dirname(paths.user_config))
        File.write(paths.user_config, "remote relay: \"127.0.0.1:7820\"\n")
        launch = Lain::Daemon::Launch.current(paths:, env: {}).with(binary: RbConfig.ruby)

        pid, note = kept_note(launch)

        expect([pid, alive?(@stand_in)]).to eq([@stand_in, true])
        expect(note).to start_with("the daemon at #{described_class.socket(paths: @paths)} is kept as it runs, " \
                                   "since the user config cannot be read: ")
        expect(note).to include(paths.user_config)
      end
    end

    it "replaces an idle one that reports no build digest, as an older build" do
      @live_runs = 0
      @info = { "launch_digest" => "older" }
      stub_const("Lain::Daemon::STOP_BUDGET", 0.2)
      launch = Lain::Daemon::Launch.current(paths: @paths).with(binary: RbConfig.ruby)

      expect { Sync { described_class.ensure(paths: @paths, launch:, env: {}) } }
        .to raise_error(Lain::Daemon::Unstopped, /#{@stand_in}/)
    end

    it "refuses in words when an idle one ignores the stop" do
      @live_runs = 0
      stub_const("Lain::Daemon::STOP_BUDGET", 0.2)
      launch = Lain::Daemon::Launch.current(paths: @paths).with(binary: RbConfig.ruby)

      expect { Sync { described_class.ensure(paths: @paths, launch:, env: {}) } }
        .to raise_error(Lain::Daemon::Unstopped, /#{@stand_in}/)
    end
  end

  describe "a binary that exits instead of serving" do
    it "refuses in words, naming its exit status and its trace" do
      socket_tmpdir("failed-daemon") do |dir|
        paths = Lain::Paths.new(env: SpecHome.env({ "XDG_RUNTIME_DIR" => dir }))
        launch = Lain::Daemon::Launch.current(paths:).with(binary: "/bin/false")

        expect { Sync { described_class.ensure(paths:, launch:, env: {}) } }
          .to raise_error(Lain::Daemon::Unstarted, /exit 1.*daemon\.trace/)
      end
    end

    it "names the signal that killed it" do
      socket_tmpdir("killed-daemon") do |dir|
        paths = Lain::Paths.new(env: SpecHome.env({ "XDG_RUNTIME_DIR" => dir }))
        binary = File.join(dir, "suicidal")
        File.write(binary, "#!/bin/sh\nkill -KILL $$\n")
        File.chmod(0o755, binary)
        launch = Lain::Daemon::Launch.current(paths:).with(binary:)

        expect { Sync { described_class.ensure(paths:, launch:, env: {}) } }
          .to raise_error(Lain::Daemon::Unstarted, /SIGKILL/)
      end
    end
  end

  describe "with the daemon opted in", :daemon do
    def fds(pid) = Dir.children("/proc/#{pid}/fd").to_h { |fd| [fd.to_i, File.readlink("/proc/#{pid}/fd/#{fd}")] }

    it "starts one in its own session at /, its stdio on /dev/null, with only the launch's env" do
      launch = daemon_launch
      pid = Sync do
        client = described_class.ensure(paths: daemon_paths, env: daemon_env)
        ping_pid(client).tap { client.stop }
      end
      skip("no /proc to read the daemon's process from") unless File.directory?("/proc/#{pid}")

      stat = File.read("/proc/#{pid}/stat").split(") ").last.split
      expect(stat[3].to_i).to eq(pid)
      expect(File.readlink("/proc/#{pid}/cwd")).to eq("/")
      expect((0..2).map { |fd| File.readlink("/proc/#{pid}/fd/#{fd}") }).to all(eq(File::NULL))
      environ = File.read("/proc/#{pid}/environ").split("\0").to_h { |pair| pair.split("=", 2) }
      expect(environ).to eq(launch.env)
      expect(environ.fetch("XDG_RUNTIME_DIR")).to eq(File.dirname(daemon_paths.runtime_dir))
    end

    # A lock or a pipe the starter holds open would otherwise be held by the daemon for its whole life.
    it "inherits no descriptor from the lain that started it" do
      Dir.mktmpdir("inherited") do |dir|
        pid = File.open(File.join(dir, "held.lock"), "w") do |inherited|
          inherited.close_on_exec = false
          Sync do
            client = described_class.ensure(paths: daemon_paths, env: daemon_env)
            ping_pid(client).tap { client.stop }
          end
        end
        skip("no /proc to read the daemon's process from") unless File.directory?("/proc/#{pid}")

        own = fds(pid).reject { |fd, target| fd <= 2 || target == daemon_launch.trace }
        expect(own.values).to all(match(/\A(?:socket|anon_inode):/))
      end
    end

    it "connects to the daemon this launch started, and says which build and settings it runs" do
      info = Sync do
        client = described_class.ensure(paths: daemon_paths, env: daemon_env)
        client.call("daemon.info").tap { client.stop }
      end

      expect(info.values_at("build_digest", "settings_digest"))
        .to eq([daemon_launch.build_digest, daemon_launch.settings_digest])
    end

    it "keeps a running daemon whose relay this chat's config lacks, and says so once" do
      devices = Lain::Remote::Devices.new(File.join(File.dirname(daemon_paths.runtime_dir), "devices", "devices"))
      devices.pair("pixel")
      port = TCPServer.open("127.0.0.1", 0) { _1.addr[1] }
      relayed = daemon_launch.with(settings: { "relay" => ["--relay", "127.0.0.1:#{port}"],
                                               "devices file" => ["--devices-file", devices.path] })
      notes = StringIO.new

      first, second, relay = Sync do
        client = described_class.ensure(paths: daemon_paths, env: daemon_env, launch: relayed)
        started = ping_pid(client).tap { client.stop }
        client = described_class.ensure(paths: daemon_paths, env: daemon_env, notes:)
        [started, ping_pid(client), client.call("daemon.info").fetch("relay")].tap { client.stop }
      end

      expect([second, relay]).to eq([first, "running"])
      expect(notes.string.lines.grep(/keeps the relay, devices file it started with/).size).to eq(1)
    end

    it "starts 1 daemon for 4 callers at once, and all 4 connect to it" do
      pids = Array.new(4) do
        Thread.new do
          Sync do
            client = described_class.ensure(paths: daemon_paths, env: daemon_env)
            ping_pid(client).tap { client.stop }
          end
        end
      end.map(&:value)

      expect(pids.uniq.size).to eq(1)
    end

    it "replaces an idle daemon from another launch" do
      socket = described_class.socket(paths: daemon_paths)
      FileUtils.mkdir_p(File.dirname(socket), mode: 0o700)
      stale = Process.spawn({ "DAEMON_LAUNCH_DIGEST" => "another #{daemon_launch.settings_digest}" },
                            daemon_launch.binary, "--socket", socket,
                            in: File::NULL, out: File::NULL, err: File::NULL)
      waiter = Process.detach(stale)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      sleep 0.02 until File.socket?(socket) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      info, pid = Sync do
        client = described_class.ensure(paths: daemon_paths, env: daemon_env)
        [client.call("daemon.info"), ping_pid(client)].tap { client.stop }
      end

      expect(waiter.join(5)).not_to be_nil
      expect(pid).not_to eq(stale)
      expect(info.fetch("build_digest")).to eq(daemon_launch.build_digest)
    end

    it "hands the daemon it starts the queue the caller gave for pushes" do
      pushes = Async::Queue.new
      allow(Lain::Core::Client).to receive(:start).and_call_original

      Sync { described_class.ensure(paths: daemon_paths, env: daemon_env, pushes:).stop }

      expect(Lain::Core::Client).to have_received(:start).with(hash_including(pushes:)).at_least(:once)
      expect(Lain::Core::Client).not_to have_received(:start).with(hash_including(pushes: nil))
    end

    it "attaches to a running daemon, and answers nil, starting none, when there is none" do
      expect(Sync { described_class.attached(paths: daemon_paths, env: daemon_env) }).to be_nil
      expect(LainDaemon.pid_at(daemon_paths)).to be_nil

      Sync { described_class.ensure(paths: daemon_paths, env: daemon_env).stop }
      client = Sync { described_class.attached(paths: daemon_paths, env: daemon_env).tap(&:stop) }

      expect(client).to be_a(Lain::Core::Client)
    end

    it "puts its socket in the example's own runtime dir" do
      Sync { described_class.ensure(paths: daemon_paths, env: daemon_env).stop }

      expect(File.socket?(described_class.socket(paths: daemon_paths))).to be(true)
      expect(described_class.socket(paths: daemon_paths)).not_to eq(described_class.socket(paths: Lain::Paths.new))
    end
  end
end
