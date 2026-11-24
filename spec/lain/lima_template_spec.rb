# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

RSpec.describe "lima/lain.yaml" do
  subject(:template) { YAML.safe_load_file(File.expand_path("../../lima/lain.yaml", __dir__)) }

  it "mounts nothing from the Mac and keeps the SSH agent out of the guest" do
    expect([template.fetch("mounts"), template.dig("ssh", "forwardAgent")]).to eq([[], false])
  end

  it "boots Ubuntu 26.04 on both architectures" do
    release = "https://cloud-images.ubuntu.com/releases/resolute/release"
    images = template.fetch("images").to_h { |image| [image.fetch("arch"), image.fetch("location")] }
    expect(images).to eq("x86_64" => "#{release}/ubuntu-26.04-server-cloudimg-amd64.img",
                         "aarch64" => "#{release}/ubuntu-26.04-server-cloudimg-arm64.img")
  end

  it "keeps containerd off" do
    expect(template.fetch("containerd")).to eq("system" => false, "user" => false)
  end

  describe "the provision step" do
    let(:both) { "libnss-resolve zsh" }
    let(:fake_commands) do
      {
        "dpkg" => <<~SH,
          shift
          for package in "$@"; do
            case " $FAKE_INSTALLED " in *" $package "*) ;; *) exit 1 ;; esac
          done
        SH
        "apt-get" => <<~SH,
          case " $* " in
            *" update "*)
              echo update >> "$FAKE_LOG"
              [ "$(grep -c '^update$' "$FAKE_LOG")" -gt "$FAKE_LOCKED_UPDATES" ] || exit 100
              ;;
            *" install "*)
              echo "$*" >> "$FAKE_LOG"
              [ "$(grep -c ' install ' "$FAKE_LOG")" -gt "$FAKE_FAILED_INSTALLS" ] || exit 100
              ;;
          esac
        SH
        "sleep" => 'echo "sleep $1" >> "$FAKE_LOG"'
      }
    end

    def provision(installed: [], locked_updates: 0, failed_installs: 0)
      script = template.fetch("provision").find { |entry| entry.fetch("mode") == "system" }.fetch("script")
      Dir.mktmpdir("lima-provision") do |dir|
        log = File.join(dir, "apt.log")
        FileUtils.touch(log)
        write_fake_commands(dir)
        env = { "PATH" => "#{dir}:#{ENV.fetch("PATH")}", "FAKE_LOG" => log,
                "FAKE_INSTALLED" => installed.join(" "), "FAKE_LOCKED_UPDATES" => locked_updates.to_s,
                "FAKE_FAILED_INSTALLS" => failed_installs.to_s }
        _, status = Open3.capture2e(env, "timeout", "15", "bash", "-c", script)
        provision_result(status, File.readlines(log, chomp: true))
      end
    end

    def write_fake_commands(dir)
      fake_commands.each do |name, body|
        File.write(File.join(dir, name), "#!/bin/bash\n#{body}\n")
        File.chmod(0o755, File.join(dir, name))
      end
    end

    def provision_result(status, lines)
      { ok: status.success?, updates: lines.count("update"), installs: lines.grep(/ install /).size,
        lock_timeout: lines.filter_map { |line| line[/DPkg::Lock::Timeout=(\d+) install/, 1] }.first,
        waited: lines.grep(/\Asleep /).sum { |line| line.split.last.to_i },
        packages: lines.filter_map { |line| line[/install -y -q (.*)/, 1] }.first }
    end

    it "installs the DNS module and shell on a guest that lacks them" do
      expect(provision).to include(ok: true, updates: 1, packages: both)
    end

    it "installs both when only the shell is present" do
      expect(provision(installed: ["zsh"])).to include(ok: true, updates: 1, packages: both)
    end

    it "installs both when only the DNS module is present" do
      expect(provision(installed: ["libnss-resolve"])).to include(ok: true, updates: 1, packages: both)
    end

    it "runs no apt when both are present, so a reboot needs no network" do
      expect(provision(installed: %w[libnss-resolve zsh])).to include(ok: true, updates: 0, waited: 0, packages: nil)
    end

    it "waits out a package lists lock that clears on the last attempt" do
      expect(provision(locked_updates: 29)).to include(ok: true, updates: 30, waited: 290, packages: both)
    end

    it "retries the update and the install when the install fails once" do
      expect(provision(failed_installs: 1))
        .to include(ok: true, updates: 2, installs: 2, waited: 10, lock_timeout: "5", packages: both)
    end

    it "has a readiness probe that passes only with both packages" do
      script = template.fetch("probes").first.fetch("script")
      Dir.mktmpdir("lima-probe") do |dir|
        write_fake_commands(dir)
        results = [%w[libnss-resolve zsh], ["zsh"], ["libnss-resolve"], []].map do |installed|
          env = { "PATH" => "#{dir}:#{ENV.fetch("PATH")}", "FAKE_INSTALLED" => installed.join(" ") }
          Open3.capture2e(env, "bash", "-c", script).last.success?
        end
        expect(results).to eq([true, false, false, false])
      end
    end

    it "fails the step when the package lists lock never clears" do
      expect(provision(locked_updates: 1000)).to include(ok: false, updates: 30, waited: 290, packages: nil)
    end
  end

  # Without guestIPMustBeZero false, loopback listeners miss this rule and hit Lima's forwarding fallback.
  it "ignores every guest port on every address and protocol" do
    expect(template.fetch("portForwards")).to eq(
      [{ "guestIP" => "0.0.0.0", "guestIPMustBeZero" => false, "proto" => "any",
         "guestPortRange" => [1, 65_535], "ignore" => true }]
    )
  end
end
