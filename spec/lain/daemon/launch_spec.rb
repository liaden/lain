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
      expect(current.env).to eq("HOME" => "/home/someone", "PATH" => "/usr/bin", "XDG_RUNTIME_DIR" => "/run/user/7",
                                "XDG_STATE_HOME" => "/home/someone/.local/state",
                                "XDG_CONFIG_HOME" => "/home/someone/.config",
                                "XDG_CACHE_HOME" => "/home/someone/.cache")
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
  end

  describe "#argv" do
    it "names the socket, the trace and the launch digest, then the flags" do
      subject = launch(flags: ["--relay", "on"].freeze)

      expect(subject.argv).to eq([subject.binary, "--socket", "/run/lain/daemon/daemon.sock",
                                  "--trace", "/run/lain/daemon/daemon.trace",
                                  "--launch-digest", subject.digest, "--relay", "on"])
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
