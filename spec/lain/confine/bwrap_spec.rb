# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe Lain::Confine::Bwrap do
  subject(:launcher) { described_class.new(fence: "/f/lain-fence") }

  let(:term) { Lain::Shell::Term.of(%w[cat README.md]) }
  let(:reader) { Lain::Confine::Profile.reader(root: "/p", home: "/h", masks: ["/p/.env"], exec_files: ["/h/.local/bin/grep"]) }

  def argv_of(wrapped) = wrapped.stages.first.argv

  describe "#wrap" do
    it "puts the reader profile's call inside bwrap, then strace, then the fence" do
      expect(argv_of(launcher.wrap(term, reader, trace_fd: 3))).to eq(
        %W[/usr/bin/bwrap --ro-bind / / --dev /dev --proc /proc
           --size #{Lain::Confine::Profile::TMPFS_BYTES} --tmpfs /tmp --unshare-pid --die-with-parent
           --ro-bind /dev/null /p/.env --
           /usr/bin/strace -DD -f -s 256 --seccomp-bpf -e trace=execve,execveat,connect,sendto,sendmsg,sendmmsg
           -o /dev/fd/3 --
           /f/lain-fence --exec-dir /usr --exec-dir /h/.rustup/toolchains --exec-file /h/.local/bin/grep
           --read-dir /p --read-dir /usr --read-dir /etc --read-dir /proc --read-dir /dev/null
           --read-dir /dev/urandom --read-dir /tmp --read-dir /h/.rustup --read-dir /h/.cargo/bin
           --read-dir /h/.config/git --read-dir /h/.gitconfig --read-dir /h/.local/share/mise/installs
           --write-dir /dev/null --write-dir /tmp --
           cat README.md]
      )
    end

    it "gives the reader profile no connect-port or unix-dir flag" do
      expect(argv_of(launcher.wrap(term, reader, trace_fd: 3))).not_to include("--connect-port", "--unix-dir")
    end

    it "turns a profile's network grants into fence flags before the separator" do
      granted = Lain::Confine::Profile.new(name: :reader, trace: false, connect_ports: [443, 80], unix_dirs: ["/run/x"])
      argv = argv_of(launcher.wrap(term, granted, trace_fd: 3))
      expect(argv[argv.index("/f/lain-fence")..]).to eq(
        %w[/f/lain-fence --connect-port 443 --connect-port 80 --unix-dir /run/x -- cat README.md]
      )
    end

    it "binds back each read dir under /tmp after the private /tmp hides it, then masks" do
      under = Lain::Confine::Profile.reader(root: "/tmp/p", home: "/h", masks: ["/tmp/p/.env"])
      expect(argv_of(launcher.wrap(term, under, trace_fd: 3)).each_cons(3).to_a).to include(
        %w[--tmpfs /tmp --unshare-pid], %w[--ro-bind-try /tmp/p /tmp/p], %w[/tmp/p --ro-bind /dev/null]
      )
    end

    it "binds back a project that is /tmp itself, and a granted program under /tmp" do
      under = Lain::Confine::Profile.reader(root: "/tmp", home: "/h", exec_files: ["/tmp/x/grep"])
      expect(argv_of(launcher.wrap(term, under, trace_fd: 3)).each_cons(3).to_a).to include(
        %w[--ro-bind-try /tmp /tmp], %w[--ro-bind-try /tmp/x/grep /tmp/x/grep]
      )
    end

    it "binds a workspace's writes back writable, then each present seal read-only, then masks" do
      seal = Lain::Confine::Profile::Seal
      workspace = Lain::Confine::Profile.new(
        name: :workspace, trace: false, read_dirs: ["/p"], write_dirs: %w[/p /h/t /dev/null /tmp],
        sealed: [seal.new(path: "/p/.envrc", absent: false), seal.new(path: "/p/.lain", absent: true)],
        masks: ["/p/.env"]
      )
      argv = argv_of(launcher.wrap(term, workspace, trace_fd: 3))
      expect(argv[(argv.index("--die-with-parent") + 1)...argv.index("--")]).to eq(
        %w[--bind-try /p /p --bind-try /h/t /h/t --ro-bind /p/.envrc /p/.envrc --ro-bind /dev/null /p/.env]
      )
    end

    it "binds each directory between a write and a seal over itself, so none of them can be renamed away" do
      seal = Lain::Confine::Profile::Seal
      workspace = Lain::Confine::Profile.new(
        name: :workspace, trace: false, read_dirs: ["/p"], write_dirs: %w[/p /dev/null /tmp],
        sealed: [seal.new(path: "/p/.git/worktrees/w/gitdir", absent: false),
                 seal.new(path: "/p/.git/commondir", absent: true), seal.new(path: "/elsewhere/hooks", absent: false)]
      )
      argv = argv_of(launcher.wrap(term, workspace, trace_fd: 3))
      expect(argv[(argv.index("--die-with-parent") + 1)...argv.index("--")]).to eq(
        %w[--bind-try /p /p --bind-try /p/.git /p/.git --bind-try /p/.git/worktrees /p/.git/worktrees
           --bind-try /p/.git/worktrees/w /p/.git/worktrees/w
           --ro-bind /p/.git/worktrees/w/gitdir /p/.git/worktrees/w/gitdir --ro-bind /elsewhere/hooks /elsewhere/hooks]
      )
    end

    it "mounts nothing at an absent seal, so the call cannot leave a file behind there" do
      workspace = Lain::Confine::Profile.new(
        name: :workspace, trace: false, write_dirs: ["/p"],
        sealed: [Lain::Confine::Profile::Seal.new(path: "/p/.lain", absent: true)]
      )
      expect(argv_of(launcher.wrap(term, workspace, trace_fd: 3))).not_to include("/p/.lain")
    end

    it "keeps its private /tmp when the project is elsewhere" do
      expect(argv_of(launcher.wrap(term, reader, trace_fd: 3))).not_to include("--ro-bind-try")
    end

    it "leaves the trace out of a reader profile that has none" do
      untraced = Lain::Confine::Profile.reader(root: "/p", home: "/h", trace: false)
      expect(argv_of(launcher.wrap(term, untraced, trace_fd: 3))).not_to include("/usr/bin/strace")
    end

    # The reaper closes every descriptor above stderr, the trace's included, so
    # the traced command cannot write its own exec lines.
    it "wraps a traced profile with strace writing to its descriptor, then the fence as a reaper only" do
      expect(argv_of(launcher.wrap(term, Lain::Confine::Profile::TRACED, trace_fd: 5))).to eq(
        ["/usr/bin/strace", "-DD", "-f", "-s", "256", "--seccomp-bpf", "-e",
         "trace=execve,execveat,connect,sendto,sendmsg,sendmmsg", "-o", "/dev/fd/5", "--",
         "/f/lain-fence", "--reap-only", "--", "cat", "README.md"]
      )
    end

    # Tracers sharing one channel interleave their lines and lose execs.
    it "gives every stage a trace descriptor of its own, each counted up from the first" do
      piped = Lain::Shell::Term.new(pipelines: [Lain::Shell::Term.of(%w[cat f], %w[head -1]).pipelines.sole,
                                                Lain::Shell::Term.of(%w[pwd]).pipelines.sole])
      wrapped = launcher.wrap(piped, Lain::Confine::Profile::TRACED, trace_fd: 3)

      expect(wrapped.stages.map { |stage| stage.argv[stage.argv.index("-o") + 1] }).to eq(
        ["/dev/fd/3", "/dev/fd/4", "/dev/fd/5"]
      )
      expect(wrapped.stages.map { _1.argv[(_1.argv.index("-o") + 2), 4] })
        .to all(eq(%w[-- /f/lain-fence --reap-only --]))
    end

    it "writes a reader stage's trace straight to its own descriptor" do
      piped = Lain::Shell::Term.of(%w[cat f], %w[head -1])
      wrapped = launcher.wrap(piped, reader, trace_fd: 3)

      expect(wrapped.stages.map { |stage| stage.argv[stage.argv.index("-o") + 1] }).to eq(%w[/dev/fd/3 /dev/fd/4])
    end

    it "runs an untraced unconfined profile under the fence as a reaper only" do
      expect(argv_of(launcher.wrap(term, Lain::Confine::Profile::NONE, trace_fd: 3)))
        .to eq(%w[/f/lain-fence --reap-only -- cat README.md])
    end

    it "prefixes every stage of every pipeline and keeps what each discards" do
      stage = ->(argv, discards = []) { Lain::Shell::Term::Stage.new(argv:, discards:) }
      piped = Lain::Shell::Term.new(pipelines: [
                                      Lain::Shell::Term::Pipeline.new(stages: [stage.call(%w[ls], [:stderr]),
                                                                               stage.call(%w[wc -l])]),
                                      Lain::Shell::Term::Pipeline.new(stages: [stage.call(%w[pwd])])
                                    ])
      wrapped = launcher.wrap(piped, Lain::Confine::Profile::TRACED, trace_fd: 3)
      expect(wrapped.pipelines.map { |pipeline| pipeline.stages.map { [_1.argv.last(2), _1.discards] } })
        .to eq([[[%w[-- ls], [:stderr]], [%w[wc -l], []]], [[%w[-- pwd], []]]])
    end
  end

  describe ".fence_binary" do
    it "is the release build in the cargo target dir" do
      expect(described_class.fence_binary(env: { "CARGO_TARGET_DIR" => "/t" })).to eq("/t/release/lain-fence")
    end
  end

  describe "a reader call on this box", :seam do
    let(:fence) { described_class.fence_binary }

    before do
      skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
      skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
      skip("bwrap cannot make a user namespace on this host") unless
        system("/usr/bin/bwrap", "--ro-bind", "/", "/", "--", "true", %i[out err] => File::NULL)
    end

    around do |example|
      Dir.mktmpdir(nil, example.metadata.fetch(:under, Dir.tmpdir)) do |dir|
        @dir = File.realpath(dir)
        example.run
      end
    end

    def project = File.join(@dir, "proj")
    def home = File.join(@dir, "home")

    def plant
      FileUtils.mkdir_p(project)
      File.write(File.join(project, "README.md"), "the readme\n")
      File.write(File.join(project, ".env"), "SECRET=1\n")
    end

    def confined(*argv)
      plant
      profile = Lain::Confine::Profile.reader(root: project, home:, masks: [File.join(project, ".env")])
      run(argv_of(described_class.new(fence:).wrap(Lain::Shell::Term.of(argv), profile, trace_fd: 3)))
    end

    def run(argv)
      reader, writer = IO.pipe
      out, err, status = Open3.capture3({ "LC_ALL" => "C" }, *argv, chdir: project, 3 => writer)
      [out, err, status.success?]
    ensure
      writer&.close
      reader&.close
    end

    # Under a TMPDIR of /tmp the private /tmp hides the file before the fence can refuse it.
    # This spec file: outside the project, outside every grant, and never under the private /tmp.
    it "refuses a file outside the project" do
      expect(confined("cat", __FILE__)).to match(["", /Permission denied/, false])
    end

    it "refuses a masked file inside the project" do
      expect(confined("cat", File.join(project, ".env"))).to match(["", /Permission denied/, false])
    end

    it "reads the project" do
      expect(confined("cat", File.join(project, "README.md"))).to eq(["the readme\n", "", true])
    end

    it "reads a project under /tmp, which the private /tmp would otherwise hide", under: "/tmp" do
      expect(confined("cat", File.join(project, "README.md"))).to eq(["the readme\n", "", true])
    end

    it "lets a forked child read its own /proc entry" do
      expect(confined("sh", "-c", "cat /proc/self/status; true")).to match([/^Name:\s+cat$/, "", true])
    end

    it "writes its private /tmp" do
      expect(confined("sh", "-c", "echo x > /tmp/scratch && cat /tmp/scratch")).to eq(["x\n", "", true])
    end

    describe "with a granted connect port" do
      def connect_to(port, granted)
        plant
        profile = Lain::Confine::Profile.reader(root: project, home:).then do |reader|
          Lain::Confine::Profile.new(**reader.to_h, connect_ports: granted)
        end
        script = "exec 3<>/dev/tcp/127.0.0.1/#{port}"
        run(argv_of(described_class.new(fence:).wrap(Lain::Shell::Term.of(["bash", "-c", script]), profile,
                                                     trace_fd: 3)))
      end

      it "connects to the granted port and is refused another" do
        granted = TCPServer.new("127.0.0.1", 0)
        other = TCPServer.new("127.0.0.1", 0)
        ports = [granted, other].map { _1.addr[1] }
        expect([connect_to(ports.first, [ports.first]).last, connect_to(ports.last, [ports.first]).last])
          .to eq([true, false])
      ensure
        [granted, other].compact.each(&:close)
      end
    end

    describe "over a repo whose listed links land on a home credential" do
      def ssh = File.join(home, ".ssh")

      def plant_repo(links)
        FileUtils.mkdir_p([project, ssh])
        File.write(File.join(ssh, "id_rsa"), "PRIVATE KEY\n")
        File.write(File.join(project, "plain.txt"), "plain words\n")
        links.each { |name, target| File.symlink(target, File.join(project, name)) }
        system(SeedRepo::SCRUB, "git", "init", "-q", chdir: project, exception: true)
      end

      def listed_masks
        policy = Lain::Sensitivity::Policy.new(
          sensitivity: Lain::Sensitivity.new(home:, cwd: project, root: project), home:, root: project
        )
        Lain::Confine::MaskList.new(root: project, policy: -> { policy }).masks.map(&:path)
      end

      def wrapped(argv, trace: true)
        profile = Lain::Confine::Profile.reader(root: project, home:, masks: listed_masks, trace:)
        argv_of(described_class.new(fence:).wrap(Lain::Shell::Term.of(argv), profile, trace_fd: 3))
      end

      # The fence refuses home before a mask is reached, so bwrap's layer runs
      # alone to show the mask itself is what hides the credential.
      def masked_only(*argv)
        full = wrapped(argv, trace: false)
        run(full.take(full.index("--") + 1) + argv)
      end

      it "still runs a command that reads an ordinary file" do
        plant_repo("ldir" => ssh)
        expect(run(wrapped(["cat", "plain.txt"]))).to eq(["plain words\n", "", true])
      end

      it "shows the masked directory empty and refuses its key" do
        plant_repo("ldir" => ssh)
        expect(masked_only("ls", "-A", "ldir")).to eq(["", "", true])
        expect(masked_only("cat", "ldir/id_rsa")).to match(["", /No such file/, false])
      end

      it "runs, and shows the directory empty, when a key link inside it is listed too" do
        plant_repo("ldir" => ssh, "lkey" => File.join(ssh, "id_rsa"))
        expect(run(wrapped(["cat", "plain.txt"]))).to eq(["plain words\n", "", true])
        expect(masked_only("ls", "-A", "ldir")).to eq(["", "", true])
      end

      it "keeps it read-only" do
        plant_repo("ldir" => ssh)
        expect(masked_only("touch", "ldir/x")).to match(["", /Read-only/, false])
      end

      it "still masks a key in a sibling directory whose name only starts with the masked one" do
        sibling = File.join("#{ssh}2", "id_rsa")
        FileUtils.mkdir_p(File.dirname(sibling))
        File.write(sibling, "PRIVATE KEY\n")
        plant_repo("ldir" => ssh, "lkey" => sibling)
        expect(masked_only("cat", "lkey")).to match(["", /Permission denied/, false])
      end

      it "reads nothing through a link to the key file" do
        plant_repo("lkey" => File.join(ssh, "id_rsa"))
        expect(masked_only("cat", "lkey")).to match(["", /Permission denied/, false])
        expect(run(wrapped(%w[cat lkey]))).to match(["", /Permission denied/, false])
      end
    end
  end

  describe "a workspace call on this box", :seam do
    let(:fence) { described_class.fence_binary }

    before do
      skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
      skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
      skip("bwrap cannot make a user namespace on this host") unless
        system("/usr/bin/bwrap", "--ro-bind", "/", "/", "--", "true", %i[out err] => File::NULL)
    end

    # Under $HOME, so a write beside the project lands somewhere the profile does not grant.
    around do |example|
      Dir.mktmpdir("lain-workspace", Dir.tmpdir.start_with?("#{Dir.home}/") ? Dir.tmpdir : Dir.home) do |dir|
        @dir = File.realpath(dir)
        FileUtils.mkdir_p([root, tmpdir])
        example.run
      end
    end

    def root = File.join(@dir, "r")
    def tmpdir = File.join(@dir, "t")
    def in_root(*names) = names.map { File.join(root, _1) }
    def ruby = File.realpath(RbConfig.ruby)

    def profile
      Lain::Confine::Profile.workspace(root:, home: Dir.home, tmpdir:, masks: in_root(".env"), exec_files: [ruby])
    end

    def wrapped(argv) = argv_of(described_class.new(fence:).wrap(Lain::Shell::Term.of(argv), profile, trace_fd: 3))

    def run(argv, env: {})
      reader, writer = IO.pipe
      call_env = { "LC_ALL" => "C", "TMPDIR" => tmpdir, "GIT_CONFIG_GLOBAL" => "/dev/null", **SeedRepo::SCRUB, **env }
      out, err, status = Open3.capture3(call_env, *argv, chdir: root, 3 => writer)
      [out, err, status.success?]
    ensure
      writer&.close
      reader&.close
    end

    def sh(script) = run(wrapped(["sh", "-c", script]))

    def appends(paths) = paths.map { "echo planted >> #{_1}" }.join("; ")

    def git_init(dir = root) = SeedRepo.git(dir, "init", "-q")

    it "writes the project and TMPDIR, and nowhere else in home" do
      outside = File.join(File.dirname(@dir), "lain-workspace-#{Process.pid}-#{rand(1 << 32)}")
      sh("touch #{File.join(root, "a")} #{File.join(tmpdir, "b")} #{outside}")

      expect([File.exist?(File.join(root, "a")), File.exist?(File.join(tmpdir, "b")), File.exist?(outside)])
        .to eq([true, true, false])
    ensure
      FileUtils.rm_f(outside)
    end

    it "keeps the persistence files read-only inside the writable project" do
      git_init
      FileUtils.mkdir_p(in_root(".lain"))
      sealed = in_root(".git/hooks/pre-commit", ".git/config", ".envrc", ".pre-commit-config.yaml", ".lain/config.rb")
      sealed.each { File.write(_1, "kept\n") unless File.exist?(_1) }
      before = sealed.to_h { [_1, File.read(_1)] }

      expect(sh(appends(sealed))[1].scan("Read-only file system").size).to eq(sealed.size)
      expect(sealed.to_h { [_1, File.read(_1)] }).to eq(before)
    end

    def commit(dir, message = "i")
      SeedRepo.git(dir, "-c", "user.name=a", "-c", "user.email=a@b", "commit", "-q",
                   "--allow-empty", "-m", message)
    end

    def inert_hook(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "exit 0\n")
    end

    def snapshot(paths) = paths.to_h { [_1, File.symlink?(_1) ? File.readlink(_1) : File.read(_1)] }

    def linked_worktree
      main = File.join(@dir, "main")
      FileUtils.mkdir_p(main)
      git_init(main)
      commit(main)
      FileUtils.rm_rf(root)
      SeedRepo.git(main, "worktree", "add", "-q", root)
      File.join(main, ".git")
    end

    it "commits in a linked worktree while the common dir's hooks and config stay sealed" do
      common = linked_worktree

      # git also tries a packed-refs.lock in the common dir, which is not granted; the commit lands without it.
      expect(run(wrapped(%w[git -c user.name=a -c user.email=a@b commit -q --allow-empty -m x])).last).to be(true)
      expect(SeedRepo.git(root, "log", "-1", "--format=%s").stdout).to eq("x\n")
      expect(sh(appends([File.join(common, "hooks", "pre-commit"), File.join(common, "config")]))[1]
        .scan("Read-only file system").size).to eq(2)
    end

    it "cannot delete a branch from a linked worktree, which needs the common dir's packed-refs" do
      common = linked_worktree
      SeedRepo.git(root, "branch", "doomed")

      expect(run(wrapped(%w[git branch -D doomed])).last).to be(false)
      expect(File.exist?(File.join(common, "refs", "heads", "doomed"))).to be(true)
    end

    it "keeps a linked worktree's pointers to its git dirs read-only" do
      common = linked_worktree
      admin = File.join(common, "worktrees", "r")
      pointers = [File.join(root, ".git"), File.join(admin, "commondir"), File.join(admin, "gitdir")]
      before = snapshot(pointers)

      expect(sh(appends(pointers))[1].scan("Read-only file system").size).to eq(3)
      expect(snapshot(pointers)).to eq(before)
    end

    it "keeps a checkout's .git from being renamed away, while git can still lock and commit inside it" do
      git_init
      before = Dir.children(File.join(root, ".git")).sort

      expect(sh("mv .git .git-old")).to match(["", /busy/i, false])
      expect(run(wrapped(%w[git -c user.name=a -c user.email=a@b commit -q --allow-empty -m x])).last).to be(true)
      expect([File.exist?(File.join(root, ".git-old")),
              before - Dir.children(File.join(root, ".git"))]).to eq([false, []])
      expect(SeedRepo.git(root, "log", "-1", "--format=%s").stdout).to eq("x\n")
    end

    it "keeps a submodule's config and hooks read-only" do
      git_init
      modules = File.join(root, ".git", "modules", "sub")
      FileUtils.mkdir_p(modules)
      File.write(File.join(modules, "config"), "[core]\n")
      inert_hook(File.join(modules, "hooks", "pre-commit"))
      planted = [File.join(modules, "config"), File.join(modules, "hooks", "pre-commit")]
      before = snapshot(planted)

      expect(sh(appends(planted))[1].scan("Read-only file system").size).to eq(2)
      expect(snapshot(planted)).to eq(before)
    end

    it "keeps every worktree's pointers back read-only, and their directory in place" do
      git_init
      commit(root)
      SeedRepo.git(root, "worktree", "add", "-q", File.join(@dir, "w2"))
      admin = File.join(root, ".git", "worktrees", "w2")
      pointers = [File.join(admin, "commondir"), File.join(admin, "gitdir")]
      before = snapshot(pointers)

      expect(sh(appends(pointers))[1].scan("Read-only file system").size).to eq(2)
      expect(sh("mv .git/worktrees .git/worktrees-old")).to match(["", /busy/i, false])
      expect(snapshot(pointers)).to eq(before)
    end

    it "keeps another worktree's config.worktree read-only from the main checkout" do
      git_init
      commit(root)
      SeedRepo.git(root, "config", "extensions.worktreeConfig", "true")
      SeedRepo.git(root, "worktree", "add", "-q", File.join(@dir, "w2"))
      config = File.join(root, ".git", "worktrees", "w2", "config.worktree")
      File.write(config, "# inert\n")

      expect(sh(appends([config]))).to match(["", /Read-only file system/, false])
      expect(File.read(config)).to eq("# inert\n")
    end

    it "keeps the whole git dir read-only when git cannot answer for it" do
      git_init
      File.write(File.join(root, ".git", "HEAD"), "not a ref\n")
      kept = [File.join(root, ".git", "HEAD"), File.join(root, ".git", "config")]
      before = snapshot(kept)

      expect(sh("#{appends(kept)}; mkdir .git/hooks/x")[1].scan("Read-only file system").size).to eq(3)
      expect(snapshot(kept)).to eq(before)
    end

    it "builds no call over a seal reached through a link the call could repoint" do
      git_init
      FileUtils.mkdir_p(in_root("real-hooks"))
      File.symlink(in_root("real-hooks").first, in_root(".husky").first)
      SeedRepo.git(root, "config", "core.hooksPath", ".husky")

      expect { wrapped(%w[true]) }.to raise_error(Lain::Confine::Profile::Unsealable)
      expect(File.readlink(in_root(".husky").first)).to eq(in_root("real-hooks").first)
    end

    it "seals a core.hooksPath directory" do
      git_init
      SeedRepo.git(root, "config", "core.hooksPath", ".husky")
      FileUtils.mkdir_p(in_root(".husky"))

      expect(sh(appends(in_root(".husky/pre-commit")))).to match(["", /Read-only file system/, false])
    end

    it "lists absent persistence files without mounting them, so a call leaves none behind" do
      git_init
      absent = in_root(".envrc", ".pre-commit-config.yaml", ".lain")

      expect(run(wrapped(%w[true]))).to eq(["", "", true])
      expect(absent.select { File.exist?(_1) }).to eq([])
    end

    it "reaches no network, by TCP or by datagram" do
      server = TCPServer.new("127.0.0.1", 0)
      udp = %(import socket; socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b"x", ("127.0.0.1", 9)))

      expect([run(wrapped(["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/#{server.addr[1]}"])).last,
              run(wrapped(["python3", "-c", udp])).last]).to eq([false, false])
    ensure
      server&.close
    end

    it "lets Ruby find its TMPDIR writable" do
      expect(run(wrapped([ruby, "-e", 'require "tmpdir"; puts Dir.tmpdir']), env: { "RUBYOPT" => nil }))
        .to eq(["#{tmpdir}\n", "", true])
    end

    # bwrap mounts the mask nodev, so even bwrap's layer alone refuses to open it, as for a reader.
    it "refuses the open, so nothing of R/.env is readable" do
      File.write(File.join(root, ".env"), "SECRET=1\n")
      full = wrapped(%w[cat .env])

      expect(run(full.take(full.index("--") + 1) + %w[cat .env])).to match(["", /Permission denied/, false])
      expect(run(full)).to match(["", /Permission denied/, false])
    end
  end
end
