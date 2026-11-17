# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Daemon::Launch do
  around do |example|
    Dir.mktmpdir("daemon-launch") do |dir|
      @dir = dir
      example.run
    end
  end

  def built(content, name: "lain-daemon")
    File.join(@dir, name).tap { |path| File.write(path, content) }
  end

  let(:binary) { built("built once") }

  def launch(**overrides)
    described_class.new(binary:, socket: "/run/lain/daemon/daemon.sock", trace: "/run/lain/daemon/daemon.trace",
                        ruby: "/usr/bin/ruby", lain: "/src/lain/exe/lain", env: { "PATH" => "/usr/bin" }.freeze,
                        flags: [].freeze, **overrides)
  end

  describe ".current" do
    let(:env) do
      { "HOME" => "/home/someone", "PATH" => "/usr/bin", "XDG_RUNTIME_DIR" => "/run/user/7",
        "ANTHROPIC_API_KEY" => "sk-secret", "LD_PRELOAD" => "/evil.so", "CARGO_TARGET_DIR" => @dir,
        "XDG_SESSION_TOKEN" => "desktop-secret", "XDG_VTNR" => "2", "XDG_SEAT" => "seat0", "LC_PAPER" => "a4" }
    end
    let(:current) { described_class.current(paths: Lain::Paths.new(env:), env:) }

    before { FileUtils.mkdir_p(File.join(@dir, "release")) && built("released", name: "release/lain-daemon") }

    it "runs the release build from cargo's target dir, on the daemon socket under the runtime dir" do
      expect(current).to have_attributes(binary: File.join(@dir, "release", "lain-daemon"),
                                         socket: "/run/user/7/lain/daemon/daemon.sock",
                                         trace: "/run/user/7/lain/daemon/daemon.trace",
                                         ruby: RbConfig.ruby,
                                         lain: File.join(Lain::Paths::Shipped::GEM_ROOT, "exe", "lain"))
    end

    it "hands the daemon only the allowlisted names, and the XDG homes its paths resolved" do
      expect(current.env.except(described_class::DIGEST))
        .to eq("HOME" => "/home/someone", "PATH" => "/usr/bin", "XDG_RUNTIME_DIR" => "/run/user/7",
               "XDG_STATE_HOME" => "/home/someone/.local/state",
               "XDG_CONFIG_HOME" => "/home/someone/.config",
               "XDG_CACHE_HOME" => "/home/someone/.cache")
    end

    # A user behind a required proxy has no other route to the topic.
    it "hands the daemon the proxy variables, in both cases" do
      proxies = %w[http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY].to_h { [_1, "http://proxy:3128"] }
      paths = Lain::Paths.new(env:)

      expect(described_class.current(paths:, env: env.merge(proxies)).env).to include(proxies)
    end

    it "takes the XDG homes from its paths when the env names others" do
      paths = Lain::Paths.new(env: env.merge("XDG_RUNTIME_DIR" => "/run/user/8", "XDG_STATE_HOME" => "/state"))

      expect(described_class.current(paths:, env:).env)
        .to include("XDG_RUNTIME_DIR" => "/run/user/8", "XDG_STATE_HOME" => "/state")
    end

    it "gives a desktop session and a login without one the same digest" do
      headless = described_class.current(paths: Lain::Paths.new(env:), env: env.except("XDG_VTNR", "XDG_SEAT"))

      expect(headless.digest).to eq(current.digest)
    end

    it "withholds a secret-shaped name even when the allowlist would take it" do
      stub_const("Lain::Daemon::Launch::KEEP", /\A(?:PATH|GH_TOKEN)\z/)

      expect(described_class.current(paths: Lain::Paths.new(env:), env: env.merge("GH_TOKEN" => "ghp")).env)
        .not_to have_key("GH_TOKEN")
    end

    it "is deeply frozen" do
      expect(Ractor.shareable?(current)).to be(true)
    end

    describe "the phone relay" do
      let(:env) do
        { "HOME" => @dir, "PATH" => "/usr/bin", "XDG_RUNTIME_DIR" => File.join(@dir, "run"),
          "CARGO_TARGET_DIR" => @dir }
      end
      let(:paths) { Lain::Paths.new(env:) }
      let(:devices) { Lain::Remote::Devices.for(paths:).path }

      def write_user_config(body)
        FileUtils.mkdir_p(File.dirname(paths.user_config))
        File.write(paths.user_config, body)
        Lain::Project::Trust.for_user(paths:).grant!
      end

      it "runs the relay the user's config sets, over the paired devices file" do
        write_user_config("remote relay: \"100.64.0.1:7820\"\n")

        expect(described_class.current(paths:, env:).flags)
          .to eq(["--relay", "100.64.0.1:7820", "--devices-file", devices])
      end

      it "gives the daemon the ntfy topic in its environment, never in its argv where every user can read it" do
        write_user_config("remote relay: \"100.64.0.1:7820\", ntfy: \"https://ntfy.sh/x-secret\"\n")
        launch = described_class.current(paths:, env:)

        expect(launch.flags).to eq(["--relay", "100.64.0.1:7820", "--devices-file", devices])
        expect(launch.argv.join(" ")).not_to include("x-secret")
        expect(launch.env).to include("DAEMON_NTFY_TOPIC" => "https://ntfy.sh/x-secret")
      end

      it "gives a topic with no relay to nobody, since only a relay has items to announce" do
        write_user_config("remote ntfy: \"https://ntfy.sh/x\"\n")
        launch = described_class.current(paths:, env:)

        expect([launch.flags, launch.env.key?("DAEMON_NTFY_TOPIC")]).to eq([[], false])
      end

      it "restarts the daemon when the topic changes, by a different digest" do
        write_user_config("remote relay: \"100.64.0.1:7820\", ntfy: \"https://ntfy.sh/x\"\n")
        first = described_class.current(paths:, env:)
        write_user_config("remote relay: \"100.64.0.1:7820\", ntfy: \"https://ntfy.sh/y\"\n")

        expect(described_class.current(paths:, env:).digest).not_to eq(first.digest)
      end

      it "writes an empty devices file, mode 0600 in a 0700 directory, before the daemon reads it" do
        write_user_config("remote relay: \"100.64.0.1:7820\"\n")
        described_class.current(paths:, env:)

        expect([File.size(devices), File.stat(devices).mode & 0o777, File.stat(File.dirname(devices)).mode & 0o777])
          .to eq([0, 0o600, 0o700])
      end

      it "keeps a devices file that already holds a pairing" do
        token = Lain::Remote::Devices.for(paths:).pair("pixel")
        write_user_config("remote relay: \"100.64.0.1:7820\"\n")
        described_class.current(paths:, env:)

        expect(File.read(devices)).to include("pixel", Lain::Ext.blake3_hex(token))
      end

      it "runs none, and writes no devices file, when the user's config sets no relay" do
        expect(described_class.current(paths:, env:).flags).to eq([])
        expect(File.exist?(devices)).to be(false)
      end

      it "runs none when the user's config cannot be read, and leaves saying why to the chat" do
        FileUtils.mkdir_p(File.dirname(paths.user_config))
        File.write(paths.user_config, "remote relay: \"100.64.0.1:7820\"\n")

        expect(described_class.current(paths:, env:).flags).to eq([])
      end

      it "gives a launch with the relay and one without different digests" do
        without = described_class.current(paths:, env:)
        write_user_config("remote relay: \"100.64.0.1:7820\"\n")

        expect(described_class.current(paths:, env:).digest).not_to eq(without.digest)
      end
    end
  end

  describe "a daemon started over the user's config", :daemon do
    after { FileUtils.rm_f(daemon_paths.user_config) }

    it "accepts a topic whose scheme has capitals, and keeps the topic out of its command line" do
      port = TCPServer.open("127.0.0.1", 0) { _1.addr[1] }
      FileUtils.mkdir_p(File.dirname(daemon_paths.user_config))
      File.write(daemon_paths.user_config, "remote relay: \"127.0.0.1:#{port}\", ntfy: \"HTTPS://ntfy.sh/x-secret\"\n")
      Lain::Project::Trust.for_user(paths: daemon_paths).grant!
      pid = Sync do
        client = Lain::Daemon.ensure(paths: daemon_paths, env: daemon_env)
        client.call("ping").fetch("pid").tap { client.stop }
      end
      skip("no /proc to read the daemon's process from") unless File.directory?("/proc/#{pid}")

      expect(File.read("/proc/#{pid}/cmdline")).not_to include("x-secret")
      expect(File.read("/proc/#{pid}/environ")).to include("DAEMON_NTFY_TOPIC=HTTPS://ntfy.sh/x-secret")
    end
  end

  describe "the topic's name, shared with the daemon", :daemon do
    after { FileUtils.rm_f(daemon_paths.user_config) }

    it "is read by the real daemon, which refuses a topic that is not http" do
      port = TCPServer.open("127.0.0.1", 0) { _1.addr[1] }
      FileUtils.mkdir_p(File.dirname(daemon_paths.user_config))
      File.write(daemon_paths.user_config, "remote relay: \"127.0.0.1:#{port}\"\n")
      Lain::Project::Trust.for_user(paths: daemon_paths).grant!
      launch = daemon_launch
      bad = launch.with(env: launch.env.merge(described_class::NTFY => "ftp://x"))

      expect { Sync { Lain::Daemon.ensure(paths: daemon_paths, env: daemon_env, launch: bad) } }
        .to raise_error(Lain::Daemon::Unstarted)
    end
  end

  describe "#argv" do
    it "names the socket and the trace, then the flags, and carries no digest" do
      subject = launch(flags: ["--relay", "on"].freeze)

      expect(subject.argv).to eq([subject.binary, "--socket", "/run/lain/daemon/daemon.sock",
                                  "--trace", "/run/lain/daemon/daemon.trace", "--relay", "on"])
    end

    # The digest hashes the topic with inputs a local user can read, so on a world-readable
    # command line it would let that user test guesses at the topic.
    it "keeps the digest out of the command line, and hands it to the daemon in its environment" do
      env = { "PATH" => "/usr/bin", "DAEMON_NTFY_TOPIC" => "x" }.freeze
      subject = launch(flags: ["--relay", "on"].freeze, env:)

      expect(subject.argv.join(" ")).not_to include(subject.digest)
      expect(subject.env.fetch("DAEMON_LAUNCH_DIGEST")).to eq(subject.digest)
    end

    it "gives a launch with another topic another digest in the environment" do
      first = launch(env: { "PATH" => "/usr/bin", "DAEMON_NTFY_TOPIC" => "x" }.freeze)
      other = first.with(env: { "PATH" => "/usr/bin", "DAEMON_NTFY_TOPIC" => "y" }.freeze)

      expect(other.env.fetch("DAEMON_LAUNCH_DIGEST")).not_to eq(first.env.fetch("DAEMON_LAUNCH_DIGEST"))
    end
  end

  describe "#digest" do
    it "is the same for the same launch" do
      expect(launch.digest).to eq(launch.digest)
    end

    # An untouched or re-copied binary keeps its content, so it must not restart the daemon.
    it "ignores the binary's mtime" do
      before = launch.digest
      File.utime(Time.at(0), Time.at(0), binary)

      expect(launch.digest).to eq(before)
    end

    it "changes with the binary's content" do
      expect(launch(binary: built("built twice", name: "other")).digest).not_to eq(launch.digest)
    end

    it "changes with the ruby, the lain and the flags" do
      digests = [launch, launch(ruby: "/opt/ruby"), launch(lain: "/elsewhere/exe/lain"),
                 launch(flags: ["--relay"].freeze)].map(&:digest)

      expect(digests.uniq.size).to eq(4)
    end

    # 2 lains whose shells differ only in whether TMPDIR is set must share 1 daemon, not restart each other's.
    it "is the same whichever allowlisted names are set, and whatever their values" do
      expect(launch(env: { "PATH" => "/opt/bin" }.freeze).digest).to eq(launch.digest)
      expect(launch(env: { "PATH" => "/usr/bin", "TMPDIR" => "/tmp" }.freeze).digest).to eq(launch.digest)
    end

    it "changes with the allowlist" do
      before = launch.digest
      stub_const("Lain::Daemon::Launch::KEEP", /\APATH\z/)

      expect(launch.digest).not_to eq(before)
    end
  end
end
