# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe "bin/ci/install-spec-binaries" do
  let(:script) { File.expand_path("../../bin/ci/install-spec-binaries", __dir__) }
  let(:box) { Dir.mktmpdir("spec-binaries") }
  let(:persist_file) { "60-lain-userns.conf" }
  let(:fake_commands) do
    {
      "id" => 'echo "$FAKE_UID"',
      "sudo" => 'exec "$@"',
      "setpriv" => <<~SH,
        [ "$1 $2 $3" = "--reuid=65534 --regid=65534 --clear-groups" ] || exit 64
        shift 3
        FAKE_UID=65534 exec "$@"
      SH
      "sysctl" => <<~SH,
        case "$1" in
          -n) [ -e "$FAKE_BOX/limit" ] || exit 255; cat "$FAKE_BOX/limit" ;;
          -w) [ -z "$FAKE_RESTORE_FAILS" ] || [ "${2##*=}" = 0 ] || exit 1; echo "${2##*=}" > "$FAKE_BOX/limit" ;;
        esac
      SH
      "tee" => 'if [ -n "$FAKE_PERSIST_FAILS" ]; then head -c 3 > "$1"; exit 1; fi; cat > "$1"',
      "mv" => '[ -z "$FAKE_MOVE_FAILS" ] || exit 1; cat "$1" > "$2"; rm -f "$1"',
      "bwrap" => <<~SH,
        [ "$1" = --version ] && { echo bubblewrap 0; exit 0; }
        case "$FAKE_HOST" in
          healthy) exit 0 ;;
          broken) exit 1 ;;
          denied)
            [ "$FAKE_UID" = 0 ] && exit 0
            case " $* " in *" --unshare-net "*) [ "$(cat "$FAKE_BOX/limit")" = 0 ] ;; esac
            ;;
        esac
      SH
      "nvim" => "echo NVIM v0.0.0",
      "tmux" => "echo fake",
      "jq" => "echo fake",
      "strace" => "echo fake",
      "curl" => "exit 1"
    }
  end

  before do
    FileUtils.mkdir_p([File.join(box, "bin"), File.join(box, "etc/sysctl.d")])
    fake_commands.each do |name, body|
      path = File.join(box, "bin", name)
      File.write(path, "#!/bin/bash\n#{body}\n")
      File.chmod(0o755, path)
    end
  end

  after { FileUtils.rm_rf(box) }

  def install(host:, uid: 1000, limit: "1", key_exists: !limit.nil?, failing: [])
    File.write(File.join(box, "limit"), "#{limit}\n") if limit
    env = { "PATH" => "#{box}/bin:#{ENV.fetch("PATH")}", "FAKE_BOX" => box, "FAKE_HOST" => host,
            "FAKE_UID" => uid.to_s, "FAKE_PERSIST_FAILS" => failing.include?(:persist) ? "1" : "",
            "FAKE_RESTORE_FAILS" => failing.include?(:restore) ? "1" : "",
            "FAKE_MOVE_FAILS" => failing.include?(:move) ? "1" : "" }
    @output, status = Open3.capture2e(env, "bash", script_on_fake_host(key_exists), "--persist", "v0.0.0")
    [status.exitstatus, read_limit, persisted]
  end

  # The real /proc/sys differs between kernels, and a spec must never write the real /etc/sysctl.d.
  def script_on_fake_host(key_exists)
    FileUtils.mkdir_p(File.join(box, "proc/sys/kernel"))
    FileUtils.touch(File.join(box, "proc/sys/kernel/apparmor_restrict_unprivileged_userns")) if key_exists
    File.join(box, "install-spec-binaries").tap do |copy|
      File.write(copy, File.read(script).gsub(%r{/(proc/sys|etc/sysctl\.d)/}) { "#{box}#{Regexp.last_match(0)}" })
    end
  end

  def read_limit
    path = File.join(box, "limit")
    File.read(path).strip if File.exist?(path)
  end

  def persisted
    Dir.children(File.join(box, "etc/sysctl.d")).sort
  end

  def persisted_text
    File.read(File.join(box, "etc/sysctl.d", persist_file))
  end

  it "leaves the limit on when the first probe passes" do
    expect(install(host: "healthy")).to eq([0, "1", []])
  end

  it "lifts and persists the limit when only a private network namespace is denied" do
    expect(install(host: "denied")).to eq([0, "0", [persist_file]])
    expect(persisted_text).to eq("kernel.apparmor_restrict_unprivileged_userns = 0\n")
  end

  it "restores the limit and persists nothing when both probes fail" do
    expect(install(host: "broken")).to eq([1, "1", []])
  end

  it "probes as an unprivileged user when run as root" do
    expect(install(host: "denied", uid: 0)).to eq([0, "0", [persist_file]])
  end

  it "changes nothing and stays quiet on a kernel without the limit" do
    expect(install(host: "broken", limit: nil)).to eq([1, nil, []])
    expect(@output).not_to include("could not read")
  end

  it "warns and changes nothing when the limit exists but cannot be read" do
    expect(install(host: "broken", limit: nil, key_exists: true)).to eq([1, nil, []])
    expect(@output).to include("warning: could not read kernel.apparmor_restrict_unprivileged_userns")
  end

  it "restores the limit and exits 1 when the persist write fails" do
    expect(install(host: "denied", failing: [:persist])).to eq([1, "1", []])
  end

  %i[persist move].each do |step|
    it "keeps an existing persist file and removes only the temporary file when the #{step} fails" do
      File.write(File.join(box, "etc/sysctl.d", persist_file), "kept\n")
      expect(install(host: "denied", failing: [step])).to eq([1, "1", [persist_file]])
      expect(persisted_text).to eq("kept\n")
    end
  end

  it "still exits 1 when the persist write and the restore both fail" do
    expect(install(host: "denied", failing: %i[persist restore])).to eq([1, "0", []])
    expect(@output).to include("warning: could not restore")
  end
end
