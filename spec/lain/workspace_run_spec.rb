# frozen_string_literal: true

require "fileutils"
require "open3"
require "socket"
require "tmpdir"

# bin/workspace-run as a person runs it: a real process, the real sandbox, a throwaway root.
RSpec.describe "bin/workspace-run", :seam do
  let(:script) { File.expand_path("../../bin/workspace-run", __dir__) }
  let(:fence) { Lain::Confine::Bwrap.fence_binary }

  around do |example|
    Dir.mktmpdir("lain-workspace-run") do |dir|
      @base = File.realpath(dir)
      %w[root home tmp other].each { FileUtils.mkdir_p(File.join(@base, _1)) }
      example.run
    end
  end

  before do
    skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
    skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
    skip("bwrap cannot make a user namespace on this host") unless
      system("/usr/bin/bwrap", "--ro-bind", "/", "/", "--", "true", %i[out err] => File::NULL)
  end

  def root = File.join(@base, "root")

  # The fixture home is the only home the run sees, so a read of its .ssh/config can never be a real one. This
  # ruby runs the script, since its `env ruby` could reach a mise shim on some PATH.
  def run(*argv, root: self.root)
    env = ENV.to_h.merge("HOME" => File.join(@base, "home"), "TMPDIR" => File.join(@base, "tmp"))
    Open3.capture3(env, RbConfig.ruby, script, "--root", root, *argv, chdir: root)
  end

  it "exits with the command's own status and passes its output through" do
    out, _err, status = run("--", "sh", "-c", "echo ran; exit 3")

    expect([out, status.exitstatus]).to eq(["ran\n", 3])
  end

  it "runs the command in the root, where it may write" do
    _out, _err, status = run("--", "sh", "-c", "echo kept > made.txt")

    expect([status.exitstatus, File.read(File.join(root, "made.txt"))]).to eq([0, "kept\n"])
  end

  it "names the profile the call ran under" do
    _out, err, = run("--", "true")

    expect(err).to include("workspace-run: profile workspace")
  end

  it "refuses a write beside the root and exits non-zero" do
    other = File.join(@base, "other", "planted")

    _out, _err, status = run("--", "sh", "-c", "echo x > #{other}")

    expect([status.success?, File.exist?(other)]).to eq([false, false])
  end

  it "refuses a read of the home's ssh config, names the path, and exits non-zero" do
    ssh = File.join(@base, "home", ".ssh").tap { FileUtils.mkdir_p(_1) }
    File.write(File.join(ssh, "config"), "Host SECRET-HOST-MARK\n")

    out, err, status = run("--", "cat", File.join(ssh, "config"))

    expect(status.success?).to be(false)
    expect(out + err).not_to include("SECRET-HOST-MARK")
    expect(err).to include(File.join(ssh, "config"))
  end

  it "prints a program the profile will not run from the sandbox record" do
    script_in_root = File.join(root, "tool.sh")
    File.write(script_in_root, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, script_in_root)

    _out, err, status = run("--", "./tool.sh")

    expect(status.success?).to be(false)
    expect(err).to include("workspace-run: refused #{script_in_root}")
  end

  # A plain call's TCP stays on a loopback of its own, so the refusal shown is a Unix socket's outside every grant,
  # as a resolver's socket is.
  it "prints a connect the profile refused from the exec record" do
    server = UNIXServer.new(sock = File.join(@base, "other", "s.sock"))
    connect = %(import socket; socket.socket(socket.AF_UNIX).connect("#{sock}"))

    _out, err, status = run("--", "python3", "-c", connect)

    expect(status.success?).to be(false)
    expect(err).to include("workspace-run: refused connect #{sock}:").and include("EACCES")
  ensure
    server&.close
  end

  def fixture_home = File.join(@base, "home")

  it "writes a private cargo home and the call's own TMPDIR, both gone after the call, the host's home untouched" do
    FileUtils.mkdir_p(File.join(fixture_home, ".cargo/registry"))
    script = %(echo made > "$HOME/.cargo/made" && cat "$HOME/.cargo/made" && echo "$TMPDIR")

    out, _err, status = run("--", "sh", "-c", script)
    made, call_dir = out.lines(chomp: true)

    expect([status.exitstatus, made]).to eq([0, "made"])
    expect([File.exist?(call_dir), File.exist?(File.join(fixture_home, ".cargo/made"))]).to eq([false, false])
  end

  it "gives a plain call a loopback of its own to bind" do
    bind = %(import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(); print("bound"))

    out, err, status = run("--", "python3", "-c", bind)

    expect([out, status.exitstatus]).to eq(["bound\n", 0]), err
  end

  it "refuses a ruby reached only through a mise shim, naming mise, and never runs it" do
    mise = File.realpath("/usr/bin/mise") if File.exist?("/usr/bin/mise")
    skip("mise is not installed at /usr/bin/mise") unless mise
    shims = File.join(fixture_home, ".local/share/mise/shims").tap { FileUtils.mkdir_p(_1) }
    File.symlink(mise, File.join(shims, "ruby"))
    env = { "HOME" => fixture_home, "TMPDIR" => File.join(@base, "tmp"), "PATH" => "#{shims}:/usr/bin:/bin" }

    # Run by this ruby, never through the script's `env ruby`, which on this PATH would be the shim itself.
    _out, err, status = Open3.capture3(ENV.to_h.merge(env),
                                       RbConfig.ruby, script, "--root", root, "--", "ruby", "-e", "1", chdir: root)

    expect(status.success?).to be(false)
    expect(err).to include("workspace-run: refused #{mise}").and include("REFUSED by the sandbox")
  end

  it "refuses a --grant that names a program other than the command's, before running anything" do
    out, err, status = run("--grant", "cargo", "--", "sh", "-c", "echo ran")

    expect([out, status.exitstatus]).to eq(["", 64])
    expect(err).to include("--grant cargo").and include("sh")
  end

  # Absent, a sealed name is only reported after the call; the tripwire scores the report and stops nothing.
  it "reports a sealed toolchain file the call created, which a later cargo run would read" do
    created = File.join(root, "rust-toolchain.toml")

    _out, err, status = run("--", "sh", "-c", "echo '[toolchain]' > rust-toolchain.toml")

    expect(status.exitstatus).to eq(0)
    expect(err).to include("workspace-run: created sealed #{created}")
  end

  it "says how to use it when the command is missing" do
    _out, err, status = run("--root", root)

    expect([status.success?, err]).to match([false, %r{usage: bin/workspace-run}])
  end
end
