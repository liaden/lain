# frozen_string_literal: true

require "fileutils"
require "open3"
require "securerandom"
require "socket"
require "timeout"
require "tmpdir"

# ABI 8 Landlock cannot refuse a Unix connect, so what keeps a confined call off the host's sockets is that
# bwrap leaves them out of its view. Listings run under bwrap alone, because the fence would refuse the read
# and an empty answer would then prove nothing.
RSpec.describe "A confined call's view of the runtime sockets", :seam do
  let(:fence) { Lain::Confine::Bwrap.fence_binary }
  let(:journal) { RecordingChannel.new }
  let(:resolver) { "/run/systemd/resolve/io.systemd.Resolve" }
  let(:user_run) { "/run/user/#{Process.uid}" }

  let(:connect) do
    <<~PY
      import errno, socket, sys
      for path in sys.argv[1:]:
          s = socket.socket(socket.AF_UNIX)
          try:
              s.connect(path)
              print(path, "OK")
          except OSError as e:
              print(path, errno.errorcode.get(e.errno, e.errno))
    PY
  end

  let(:every_dns_route) do
    <<~PY
      import errno, json, socket
      def outcome(attempt):
          try:
              return attempt()
          except socket.gaierror as e:
              return "gaierror"
          except OSError as e:
              return errno.errorcode.get(e.errno, str(e))
      def varlink():
          s = socket.socket(socket.AF_UNIX)
          s.settimeout(2)
          s.connect("#{resolver}")
          query = {"method": "io.systemd.Resolve.ResolveHostname", "parameters": {"name": "example.com"}}
          s.sendall(json.dumps(query).encode() + b"\\0")
          return "ANSWERED" if s.recv(4096) else "closed"
      def udp(host):
          s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
          s.settimeout(2)
          s.sendto(b"\\x12\\x34\\x01\\x00\\x00\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x07example\\x03com\\x00\\x00\\x01\\x00\\x01", (host, 53))
          s.recv(512)
          return "ANSWERED"
      def tcp(host):
          socket.create_connection((host, 53), 2)
          return "ANSWERED"
      print("varlink", outcome(varlink))
      print("getaddrinfo", outcome(lambda: "ANSWERED" if socket.getaddrinfo("example.com", 443) else "none"))
      for host in ("127.0.0.53", "1.1.1.1"):
          print("udp", host, outcome(lambda: udp(host)))
          print("tcp", host, outcome(lambda: tcp(host)))
    PY
  end

  around do |example|
    Dir.mktmpdir("r") do |dir|
      @base = File.realpath(dir)
      @repo, @home, @tmp = %w[repo home tmp].map { File.join(@base, _1) }
      FileUtils.mkdir_p([@repo, @home, @tmp])
      SeedRepo.git(@repo, "init", "-q")
      example.run
    end
  end

  before do
    skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace /usr/bin/python3]
                                                    .all? { File.executable?(_1) }
    skip("lain-fence is not built at #{fence}") unless File.executable?(fence)
    skip("bwrap cannot make a user namespace on this host") unless
      system("/usr/bin/bwrap", "--ro-bind", "/", "/", "--", "true", %i[out err] => File::NULL)
  end

  def env_with(runtime) = ENV.to_h.except("XDG_RUNTIME_DIR").merge(runtime ? { "XDG_RUNTIME_DIR" => runtime } : {})

  def workspace(**changes)
    Lain::Confine::Profile.workspace(root: @repo, home: @home, tmpdir: @tmp, trace: false)
                          .with(private_net: true, **changes)
  end

  def granted = Lain::Confine::Profile.grant(program: "git", root: @repo, home: @home, tmpdir: @tmp, trace: false)

  def wrapped(profile, argv, env)
    launcher = Lain::Confine::Bwrap.on_path(fence:, env:)
    bound = launcher.masked(profile).bind(stages: 1, first_fd: 4)
    yield launcher.wrap(Lain::Shell::Term.of(argv), profile, trace_fd: 3, bound:).stages.first.argv, bound.fds
  ensure
    bound&.close
  end

  def confined(profile, *argv, env: ENV.to_h)
    wrapped(profile, argv, env) do |full, fds|
      Open3.capture3("timeout", "20", *full, chdir: @repo, **fds)
    end
  end

  def bwrap_alone(profile, *argv, env: ENV.to_h)
    wrapped(profile, argv, env) do |full, fds|
      Open3.capture3("timeout", "20", *full.take(full.index("--") + 1), *argv, chdir: @repo, **fds)
    end
  end

  def nss_resolve? = File.read("/etc/nsswitch.conf").match?(/^hosts:.*\bresolve\b/)

  def in_user_run
    skip("#{user_run} is not writable here") unless File.writable?(user_run)
    dir = File.join(user_run, "l#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(dir)
    yield dir
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  def listening(paths)
    FileUtils.mkdir_p(paths.map { File.dirname(_1) })
    servers = paths.map { UNIXServer.new(_1) }
    yield
  ensure
    servers&.each(&:close)
  end

  def lain_sockets(runtime)
    paths = Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => runtime, "HOME" => @home })
    [paths.spawner_socket, File.join(paths.runtime_dir, "input-abc-main.sock"),
     Lain::Daemon.socket(paths:), File.join(paths.runtime_dir, "nvim-abc.sock")]
  end

  def through_sandbox(runtime, command)
    saved = ENV.fetch("XDG_RUNTIME_DIR", nil)
    ENV["XDG_RUNTIME_DIR"] = runtime
    policy = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: @home, cwd: @repo, root: @repo),
                                           home: @home, root: @repo)
    masks = Lain::Confine::MaskList.new(root: @repo, policy: -> { policy }, journal:)
    sandboxed = Lain::Confine::Sandbox.new(root: @repo, home: @home, masks:, fence:, journal:,
                                           probe: Lain::Confine::Probe.new(fence:, journal:))
                                      .wrap(Lain::Exec::Local.new, requirer: "Spec")
    ruling = Lain::Approval::Escalation::Ruling.allow(rung: "surfaces", because: "spec", authority: :human,
                                                      contained: true)
    request = Lain::Confine::Request.new(ruling:, executables: [], cwd: @repo, root: @repo, tool_use_id: "toolu_1",
                                         bounds: policy.bounds)
    sandboxed.call(command:, cwd: @repo, env: {}, timeout: 15, confinement: request)
  ensure
    ENV["XDG_RUNTIME_DIR"] = saved
  end

  # The real /tmp/lain may belong to a running lain, so only a uniquely named socket is added to it.
  def socket_in_tmp_fallback
    made = !Dir.exist?("/tmp/lain")
    FileUtils.mkdir_p("/tmp/lain", mode: 0o700)
    path = "/tmp/lain/spec-#{SecureRandom.hex(4)}.sock"
    server = UNIXServer.new(path)
    yield path
  ensure
    server&.close
    FileUtils.rm_f(path) if path
    Dir.rmdir("/tmp/lain") if made && Dir.empty?("/tmp/lain")
  end

  describe "a grant under /run" do
    it "writes inside the grant, keeps a sibling hidden, and leaves /run read-only" do
      in_user_run do |dir|
        grant = File.join(dir, "granted")
        sibling = File.join(dir, "sibling")
        FileUtils.mkdir_p([grant, sibling])
        profile = workspace(read_dirs: [*workspace.read_dirs, grant], write_dirs: [*workspace.write_dirs, grant])

        _, written_err, written = confined(profile, "/usr/bin/touch", File.join(grant, "made"))
        _, _, seen = bwrap_alone(profile, "/usr/bin/ls", sibling)
        _, run_err, remounted = bwrap_alone(profile, "/usr/bin/touch", "/run/planted")

        expect(written.success?).to be(true), written_err
        expect(File).to exist(File.join(grant, "made"))
        expect(seen.success?).to be(false)
        expect([remounted.success?, run_err]).to match([false, /Read-only file system/])
      end
    end
  end

  describe "a call with no network" do
    before { skip("no resolver socket on this box") unless File.socket?(resolver) }

    it "reaches the resolver from outside the sandbox, so a refusal inside means something" do
      out, = Open3.capture2("/usr/bin/python3", "-c", connect, resolver)

      expect(out).to include("#{resolver} OK")
    end

    it "cannot resolve a name by any route, and is told promptly" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, err, = confined(workspace, "/usr/bin/python3", "-c", every_dns_route)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(out.lines.size).to eq(6), err
      expect(out).not_to include("ANSWERED")
      expect(out).to match(/^varlink ENOENT$/).and match(/^getaddrinfo gaierror$/)
      expect(elapsed).to be < 15
    end

    it "fails a plain getent hosts without hanging" do
      _, _, status = confined(workspace, "/usr/bin/getent", "hosts", "example.com")

      expect(status.exitstatus).to eq(2)
    end
  end

  it "shows a workspace call only the resolv.conf landing and its parents under /run" do
    landing = File.realpath("/etc/resolv.conf")
    skip("resolv.conf does not land under /run here") unless landing.start_with?("/run/")
    parents = Pathname(landing).ascend.map(&:to_s).select { _1.start_with?("/run") }

    out, err, status = bwrap_alone(workspace, "/usr/bin/find", "/run")

    expect(status.success?).to be(true), err
    expect(out.lines(chomp: true)).to match_array(parents)
  end

  it "resolves a public name for a grant through real getaddrinfo" do
    skip("this box does not resolve through nss-resolve") unless nss_resolve?
    skip("this box cannot resolve github.com") unless system("getent", "hosts", "github.com", out: File::NULL)

    out, err, status = confined(granted, "/usr/bin/python3", "-c",
                                "import socket; print(socket.getaddrinfo('github.com', 443)[0][4][0])")

    expect(status.success?).to be(true), err
    expect(out.strip).to match(/\A[\h:.]+\z/)
  end

  describe "lain's own sockets, through the production Sandbox" do
    def unconfined_answers(sockets)
      Open3.capture2("/usr/bin/python3", "-c", connect, *sockets).first.lines.map { _1.split.last }
    end

    def expect_refused(result, sockets)
      expect(result.stdout.lines.map { _1.split.first }).to eq(sockets), result.stderr
      expect(result.stdout).not_to match(/ OK$/)
    end

    def expect_unreachable(runtime)
      sockets = lain_sockets(runtime)
      File.write(File.join(@repo, "connect.py"), connect)
      listening(sockets) do
        expect(unconfined_answers(sockets)).to eq(["OK"] * 4)
        expect_refused(through_sandbox(runtime, "/usr/bin/python3 connect.py #{sockets.join(" ")}"), sockets)
      end
    end

    it "refuses each one where the runtime dir is under /run" do
      in_user_run { |dir| expect_unreachable(dir) }
    end

    it "refuses each one where the runtime dir is outside /run" do
      expect_unreachable(File.join(@base, "rt"))
    end
  end

  it "keeps systemd from running a command for the call" do
    skip("no user bus on this box") unless File.socket?(File.join(user_run, "bus"))
    outside = File.join(@base, "outside")

    confined(workspace, "/usr/bin/systemd-run", "--user", "--wait", "--quiet", "/usr/bin/touch", outside,
             env: ENV.to_h.merge("XDG_RUNTIME_DIR" => user_run))

    expect(File).not_to exist(outside)
  end

  it "hides a runtime directory outside /run" do
    runtime = File.join(@base, "rt")
    sockets = lain_sockets(runtime)

    listening(sockets) do
      out, err, status = bwrap_alone(workspace, "/usr/bin/ls", "-A", runtime, env: env_with(runtime))

      expect(status.success?).to be(true), err
      expect(out).to eq("")
    end
  end

  it "keeps a sibling of lain's folder in a runtime directory outside /run out of reach" do
    runtime = File.join(@base, "rt")
    bus = File.join(runtime, "bus")

    listening([bus]) do
      out, err, = confined(workspace, "/usr/bin/python3", "-c", connect, bus, env: env_with(runtime))

      expect(out).to eq("#{bus} ENOENT\n"), err
    end
  end

  it "keeps a sibling socket hidden from a project that is the runtime directory" do
    runtime = File.join(@base, "rt")
    bus = File.join(runtime, "bus")

    listening([bus]) do
      at_runtime = Lain::Confine::Profile.workspace(root: runtime, home: @home, tmpdir: @tmp, trace: false)
                                         .with(private_net: true)
      out, err, = confined(at_runtime, "/usr/bin/python3", "-c", connect, bus, env: env_with(runtime))

      expect(out).to eq("#{bus} ENOENT\n"), err
    end
  end

  it "keeps the bus hidden under a read grant of a runtime directory in /run" do
    skip("no user bus on this box") unless File.socket?(File.join(user_run, "bus"))
    base = workspace

    _, _, status = bwrap_alone(base.with(read_dirs: [*base.read_dirs, user_run]), "/usr/bin/test", "-e",
                               File.join(user_run, "bus"), env: env_with(user_run))

    expect(status.exitstatus).to eq(1)
  end

  it "keeps a lain socket made after the call started out of reach" do
    runtime = File.join(@base, "rt")
    FileUtils.mkdir_p(runtime)
    socket = File.join(runtime, "lain", "spawner.sock")
    late = <<~PY
      import errno, os, socket, sys, time
      open("started", "w").close()
      deadline = time.time() + 10
      while not os.path.exists("go") and time.time() < deadline:
          time.sleep(0.01)
      s = socket.socket(socket.AF_UNIX)
      try:
          s.connect(sys.argv[1])
          print("OK")
      except OSError as e:
          print(errno.errorcode.get(e.errno, e.errno))
    PY
    call = Thread.new { confined(workspace, "/usr/bin/python3", "-c", late, socket, env: env_with(runtime)) }
    started = File.join(@repo, "started")
    Timeout.timeout(10) { Thread.pass until File.exist?(started) || !call.alive? }

    listening([socket]) do
      File.write(File.join(@repo, "go"), "")
      out, err, = call.value

      expect(out).to eq("ENOENT\n"), err
    end
  end

  describe "a grant that would restore the real /run" do
    before { skip("no user bus on this box") unless File.socket?(File.join(user_run, "bus")) }

    { "a read grant of /run/" => { read_dirs: ["/run/"] }, "a write grant of /run" => { write_dirs: ["/run"] },
      "a write grant of /" => { write_dirs: ["/"] } }.each do |name, grants|
      it "keeps the bus hidden under #{name}" do
        base = workspace
        profile = base.with(**grants.to_h { |key, value| [key, [*base.public_send(key), *value]] })

        _, _, status = bwrap_alone(profile, "/usr/bin/test", "-e", File.join(user_run, "bus"))

        expect(status.exitstatus).to eq(1)
      end
    end
  end

  describe "git state a call wrote, read back by the next call" do
    let(:script) { File.expand_path("../../../bin/workspace-run", __dir__) }
    let(:run_env) do
      ENV.to_h.merge("XDG_STATE_HOME" => File.join(@base, "state"), "XDG_CACHE_HOME" => File.join(@base, "cache"))
    end

    before { FileUtils.rm_rf(File.join(@repo, ".git")) }

    def workspace_run(*argv, root: @repo, env: run_env)
      Open3.capture3(env, "timeout", "30", RbConfig.ruby, script, "--root", root, "--", *argv, chdir: root)
    end

    def forged_git_dir(hooks)
      plant("mkdir -p .git/objects .git/refs/heads; echo ref: refs/heads/main > .git/HEAD; " \
            "printf '[core]\\n\\trepositoryformatversion = 0\\n\\thooksPath = #{hooks}\\n' > .git/config")
    end

    def hook_at(dir)
      FileUtils.mkdir_p(dir)
      File.write(hook = File.join(dir, "pre-commit"), "#!/bin/sh\ntouch hook-ran\n")
      File.chmod(0o755, hook)
    end

    def reached(path) = workspace_run("/usr/bin/python3", "-c", connect, path).first[/^#{Regexp.escape(path)} (\S+)/, 1]

    def plant(shell) = workspace_run("/usr/bin/bash", "-c", shell).tap { expect(_1.last.success?).to be(true), _1[1] }

    it "does not bind a forged pointer at the user's runtime directory" do
      in_user_run do |dir|
        socket = File.join(dir, "l.sock")
        listening([socket]) do
          plant("echo 'gitdir: #{dir}' > .git")

          expect(reached(socket)).to eq("ENOENT")
        end
      end
    end

    it "does not let a no-network call reach the resolver through a forged pointer" do
      skip("no resolver socket on this box") unless File.socket?(resolver)
      plant("echo 'gitdir: /run/systemd/resolve' > .git")

      expect(reached(resolver)).to eq("ENOENT")
    end

    it "does not follow a forged admin dir whose commondir names /run" do
      in_user_run do |dir|
        socket = File.join(dir, "l.sock")
        listening([socket]) do
          plant("mkdir -p fake/worktrees/w; echo #{@repo}/.git > fake/worktrees/w/gitdir; " \
                "echo #{dir} > fake/worktrees/w/commondir; echo 'gitdir: #{@repo}/fake/worktrees/w' > .git")

          expect(reached(socket)).to eq("ENOENT")
        end
      end
    end

    it "does not bind a hooks path under /run from a forged git dir" do
      in_user_run do |dir|
        socket = File.join(dir, "l.sock")
        listening([socket]) do
          plant("mkdir -p .git/objects .git/refs/heads; echo ref: refs/heads/main > .git/HEAD; " \
                "printf '[core]\\n\\trepositoryformatversion = 0\\n\\thooksPath = #{dir}\\n' > .git/config")

          expect(reached(socket)).to eq("ENOENT")
        end
      end
    end

    describe "a forged pointer at another real repository" do
      let(:other) { File.join(@base, "other") }
      let(:description) { File.join(other, ".git", "description") }

      before { SeedRepo.git(@base, "init", "-q", other) }

      def expect_no_write(forge)
        before = File.read(description)
        plant(forge)

        out, err, = workspace_run("/usr/bin/bash", "-c", "echo planted > #{description}")

        expect(out + err).to match(/Permission denied|Read-only file system|REFUSED/)
        expect(File.read(description)).to eq(before)
      end

      it "gets no write into it through a .git file" do
        expect_no_write("echo 'gitdir: #{other}/.git' > .git")
      end

      it "gets no write into it through a .git directory naming it as commondir" do
        expect_no_write("mkdir -p .git/objects .git/refs; echo ref: refs/heads/main > .git/HEAD; " \
                        "echo #{other}/.git > .git/commondir")
      end

      it "gets no write into it through a .git link" do
        expect_no_write("ln -s #{other}/.git .git")
      end
    end

    describe "a planted git layout beside a victim repository" do
      let(:victim) { File.join(@base, "victim") }
      let(:refs_plant) { File.join(victim, ".git", "refs", "planted") }
      let(:identity) { %w[-c user.email=spec@example.invalid -c user.name=spec] }

      before do
        SeedRepo.git(@base, "init", "-q", victim)
        SeedRepo.git(victim, *identity, "commit", "-q", "--allow-empty", "-m", "first")
        File.write(File.join(victim, ".git", "description"), "zq_victim_mark\n")
      end

      it "runs git status, log, diff and rev-parse in a project inside a repository" do
        parent = File.join(@base, "parent")
        FileUtils.mkdir_p(inner = File.join(parent, "inner"))
        SeedRepo.git(parent, "init", "-q")
        File.write(File.join(inner, "f"), "x\n")
        SeedRepo.git(parent, "add", "-A")
        SeedRepo.git(parent, *identity, "commit", "-q", "-m", "zq_parent_commit")
        File.write(File.join(inner, "f"), "y\n")
        script = "git status --short && git log --oneline -1 && git diff --stat && git rev-parse --show-toplevel"

        out, err, status = workspace_run("/usr/bin/bash", "-c", script, root: inner)

        expect(status.success?).to be(true), err
        expect(out).to include("M f").and include("zq_parent_commit").and include("1 file changed")
        expect(out.lines.last.strip).to eq(parent)
      end

      it "gives a project inside a repository no write through a planted parent commondir" do
        parent = File.join(@base, "parent")
        FileUtils.mkdir_p(inner = File.join(parent, "inner"))
        SeedRepo.git(parent, "init", "-q")
        File.write(File.join(parent, ".git", "commondir"), "#{victim}/.git\n")

        workspace_run("/usr/bin/bash", "-c", "echo x > #{refs_plant}", root: inner)

        expect(File).not_to exist(refs_plant)
      end

      it "stops a project inside a repository rewriting the parent's HEAD" do
        parent = File.join(@base, "parent")
        FileUtils.mkdir_p(inner = File.join(parent, "inner"))
        SeedRepo.git(parent, "init", "-q")
        head = File.join(parent, ".git", "HEAD")
        before = File.read(head)

        workspace_run("/usr/bin/bash", "-c", "echo planted >> #{head}", root: inner)

        expect(File.read(head)).to eq(before)
      end

      it "gives an unrelated project nothing from a config planted in a worktree's admin dir" do
        linked = File.join(@base, "linked")
        SeedRepo.git(victim, "worktree", "add", "-q", linked)
        admin = File.join(victim, ".git", "worktrees", "linked")
        File.write(File.join(admin, "config"), "[core]\n\tworktree = #{@repo}\n")
        File.write(File.join(@repo, ".git"), "gitdir: #{admin}\n")

        out, = workspace_run("/usr/bin/bash", "-c", "cat #{victim}/.git/description; echo x > #{refs_plant}")

        expect(out).not_to include("zq_victim_mark")
        expect(File).not_to exist(refs_plant)
      end

      it "reads nothing through an admin dir in the project swapped for a link after the check" do
        FileUtils.mkdir_p(admin = File.join(@repo, ".f"))
        File.write(File.join(@repo, ".git"), "gitdir: .f\n")
        File.write(File.join(admin, "gitdir"), "#{@repo}/.git\n")
        reader = Lain::Confine::Profile.reader(root: @repo, home: @home, trace: false)
        File.rename(admin, "#{admin}2")
        File.symlink("#{victim}/.git", admin)

        out, = confined(reader, "/usr/bin/cat", "#{victim}/.git/description")

        expect(out).not_to include("zq_victim_mark")
      end
    end

    it "keeps the real /run and the host /tmp hidden under a forged hooks path of /" do
      Dir.mktmpdir("h", "/tmp") do |host|
        in_user_run do |dir|
          sockets = [File.join(host, "l.sock"), File.join(dir, "l.sock")]
          listening(sockets) do
            forged_git_dir("/")

            expect(sockets.map { reached(_1) }).to eq(%w[ENOENT ENOENT])
          end
        end
      end
    end

    describe "a hooks path in a config the call wrote" do
      it "grants no read of a host directory" do
        FileUtils.mkdir_p(host = File.join(@base, "host"))
        File.write(note = File.join(host, "note"), "fixture-private\n")
        forged_git_dir(host)

        out, err, = workspace_run("/usr/bin/cat", note)

        expect(out).not_to include("fixture-private")
        expect(err).to include("Permission denied")
      end

      it "does not bring a socket under the host /tmp into view" do
        Dir.mktmpdir("h", "/tmp") do |host|
          socket = File.join(host, "l.sock")
          listening([socket]) do
            forged_git_dir(host)

            expect(reached(socket)).to eq("ENOENT")
          end
        end
      end
    end

    context "with a real repository" do
      let(:identity) { %w[-c user.email=spec@example.invalid -c user.name=spec] }

      before do
        SeedRepo.git(@repo, "init", "-q")
        SeedRepo.git(@repo, *identity, "commit", "-q", "--allow-empty", "-m", "first")
      end

      it "keeps git working in a real linked worktree, commits included" do
        linked = File.join(@base, "linked")
        SeedRepo.git(@repo, "worktree", "add", "-q", linked)

        out, err, status = workspace_run("/usr/bin/git", *identity, "commit", "-q", "--allow-empty", "-m", "second",
                                         root: linked)

        expect(status.success?).to be(true), out + err
        expect(SeedRepo.git(linked, "log", "-1", "--format=%s").stdout).to include("second")
      end

      it "still answers and seals a hooks path inside the project" do
        hook_at(File.join(@repo, ".githooks"))
        SeedRepo.git(@repo, "config", "core.hooksPath", ".githooks")

        out, = workspace_run("/usr/bin/git", "rev-parse", "--git-path", "hooks")
        _, err, = workspace_run("/usr/bin/bash", "-c", "echo planted > .githooks/pre-commit")

        expect(out).to include(".githooks")
        expect(err).to match(/Read-only file system|Permission denied/)
        expect(File.read(File.join(@repo, ".githooks", "pre-commit"))).not_to include("planted")
      end

      it "runs a hooks path outside the project that global config names" do
        hook_at(hooks = File.join(@base, "global-hooks"))
        File.write(File.join(@home, ".gitconfig"), "[core]\n\thooksPath = #{hooks}\n")
        env = run_env.except("GIT_CONFIG_GLOBAL").merge("HOME" => @home, "TMPDIR" => @tmp, "GIT_CONFIG_GLOBAL" => nil)

        _, err, status = workspace_run("/usr/bin/git", *identity, "commit", "-q", "--allow-empty", "-m", "hooked", env:)

        expect(status.success?).to be(true), err
        expect(File).to exist(File.join(@repo, "hook-ran"))
      end

      it "keeps git reading a real submodule used as the project" do
        upstream = File.join(@base, "upstream")
        SeedRepo.git(@base, "init", "-q", upstream)
        SeedRepo.git(upstream, *identity, "commit", "-q", "--allow-empty", "-m", "upstream")
        SeedRepo.git(@repo, *identity, "-c", "protocol.file.allow=always", "submodule", "add", "-q", upstream, "sub")

        out, err, status = workspace_run("/usr/bin/git", "log", "-1", "--format=%s", root: File.join(@repo, "sub"))

        expect(status.success?).to be(true), err
        expect(out).to include("upstream")
      end
    end
  end

  it "starts and runs the term where the runtime directory has no lain folder" do
    runtime = File.join(@base, "empty")
    FileUtils.mkdir_p(runtime)
    reader = Lain::Confine::Profile.reader(root: @repo, home: @home, trace: false)

    out, err, status = confined(reader, "/usr/bin/echo", "ran", env: env_with(runtime))

    expect([out, status.success?]).to eq(["ran\n", true]), err
  end

  it "keeps the /tmp fallback hidden when the project is /tmp" do
    socket_in_tmp_fallback do |socket|
      at_tmp = Lain::Confine::Profile.reader(root: "/tmp", home: @home, trace: false)

      out, err, status = bwrap_alone(at_tmp, "/usr/bin/ls", "-A", "/tmp/lain", env: env_with(nil))

      expect(File).to be_socket(socket)
      expect([out, status.success?]).to eq(["", true]), err
    end
  end

  # Ubuntu's AppArmor refuses a user namespace inside bwrap's, so no outer namespace can take /run away.
  # An absent path in the constant's place gives real bwrap the same missing target.
  it "starts and runs the term on a box with no /run" do
    absent = File.join(@base, "no-run")
    aborted = system("/usr/bin/bwrap", "--ro-bind", "/", "/", "--tmpfs", absent, "--", "/usr/bin/true", err: File::NULL)
    stub_const("Lain::Confine::Bwrap::RUN", absent)
    reader = Lain::Confine::Profile.reader(root: @repo, home: @home, trace: false)

    out, err, status = confined(reader, "/usr/bin/echo", "ran", env: env_with(nil))

    expect(aborted).to be(false)
    expect([out, status.success?]).to eq(["ran\n", true]), err
  end

  describe "name lookups" do
    it "answers id and getent passwd for the user" do
      name = Etc.getpwuid.name

      id_out, id_err, = confined(workspace, "/usr/bin/id", "-un")
      passwd, passwd_err, = confined(workspace, "/usr/bin/getent", "passwd", name)

      expect(id_out.strip).to eq(name), id_err
      expect(passwd).to start_with("#{name}:"), passwd_err
    end

    it "does not hang on logger" do
      _, _, status = confined(workspace, "/usr/bin/logger", "lain runtime socket spec")

      expect(status.exitstatus).not_to eq(124)
    end
  end
end
