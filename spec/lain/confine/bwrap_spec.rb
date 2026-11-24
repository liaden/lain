# frozen_string_literal: true

require "fileutils"
require "open3"
require "securerandom"
require "tmpdir"

RSpec.describe Lain::Confine::Bwrap do
  subject(:launcher) { described_class.new(fence: "/f/lain-fence", home: "/h") }

  let(:term) { Lain::Shell::Term.of(%w[cat README.md]) }
  let(:reader) { Lain::Confine::Profile.reader(root: "/p", home: "/h", masks: ["/p/.env"], exec_files: ["/h/.local/bin/grep"]) }
  let(:opened) { [] }

  def argv_of(wrapped) = wrapped.stages.first.argv

  def binds_in(argv)
    binds = argv[(argv.index("--die-with-parent") + 1)...argv.index("--")]
    binds.last(2) == %w[--remount-ro /run] ? binds[...-2] : binds
  end

  after { opened.each(&:close) }

  around do |example|
    saved = ENV.delete("XDG_RUNTIME_DIR")
    example.run
  ensure
    ENV["XDG_RUNTIME_DIR"] = saved
  end

  # Each stage's mask descriptors, opened as Exec::Sandboxed opens them: numbered after every stage's trace.
  def wrapping(launcher, term, profile, trace_fd: 3)
    stages = term.stages.size
    bound = launcher.masked(profile).bind(stages:, first_fd: trace_fd + stages)
    opened << bound
    launcher.wrap(term, profile, trace_fd:, bound:)
  end

  # What the last wrap hands its spawn, beside the trace descriptor.
  def handed = opened.last&.fds || {}

  describe "#wrap" do
    it "puts the reader profile's call inside bwrap, then strace, then the fence" do
      expect(argv_of(wrapping(launcher, term, reader, trace_fd: 3))).to eq(
        %W[/usr/bin/bwrap --ro-bind / / --dev /dev --proc /proc
           --size #{Lain::Confine::Profile::TMPFS_BYTES} --tmpfs /tmp --size 1048576 --tmpfs /run
           --unshare-pid --die-with-parent
           --perms 0400 --ro-bind-data 4 /p/.env --remount-ro /run --
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

    describe "the files it binds beside the masks" do
      let(:extra) { { "/tmp/.extra" => "a" * 200_000 } }

      it "binds one of any size, each stage reading it whole from a descriptor of its own" do
        bound = launcher.masked(reader).bind(stages: 2, first_fd: 5, also: extra)
        opened << bound

        expect(bound.fds.values_at(6, 8).map { _1.read.bytesize }).to eq([200_000, 200_000])
      end

      # The project's own /tmp is then bound back read-only, where bwrap could not make the file.
      it "binds none where the project is /tmp itself" do
        at_tmp = Lain::Confine::Profile.reader(root: "/tmp", home: "/h", masks: ["/tmp/.env"])
        bound = launcher.masked(at_tmp).bind(stages: 1, first_fd: 4, also: extra)
        opened << bound

        expect([bound.argv(0), bound.fds.keys]).to eq([%w[--perms 0400 --ro-bind-data 4 /tmp/.env], [4]])
      end

      it "reads each file from what it wrote, though a link replaced its path before the reopen" do
        Dir.mktmpdir("lain-host") do |host|
          File.write(secret = File.join(host, "secret"), "host secret\n")
          allow(Tempfile).to receive(:create).and_wrap_original do |create, *args, **options, &block|
            create.call(*args, **options) do |file|
              allow(file).to receive(:flush).and_wrap_original do |flush|
                flush.call.tap do
                  File.unlink(file.path)
                  File.symlink(secret, file.path)
                end
              end
              block.call(file)
            end
          end
          bound = launcher.masked(reader).bind(stages: 1, first_fd: 4, also: { "/tmp/.extra" => "mine" })
          opened << bound

          expect(bound.fds.fetch(5).read).to eq("mine")
        end
      end

      it "closes every descriptor it opened when binding fails part way" do
        made = []
        allow(File).to receive(:new).and_wrap_original do |make, *args, **options, &block|
          raise Errno::EMFILE if made.size == 3

          make.call(*args, **options, &block).tap { made << _1 }
        end

        expect { launcher.masked(reader).bind(stages: 3, first_fd: 4, also: extra) }.to raise_error(Errno::EMFILE)
        expect(made).to all(be_closed)
      end
    end

    # A path source would be followed on the host, so a link planted there could read any host file.
    it "binds every mask from a descriptor of each stage's own, and none from a path" do
      masked = Lain::Confine::Profile.reader(root: "/p", home: "/h", masks: %w[/p/.env /p/config/master.key])
      stages = wrapping(launcher, Lain::Shell::Term.of(%w[cat a], %w[head -1]), masked).stages

      expect(stages.map { |stage| stage.argv.each_cons(5).select { _1[2] == "--ro-bind-data" } }).to eq(
        [[%w[--perms 0400 --ro-bind-data 5 /p/.env], %w[--perms 0400 --ro-bind-data 6 /p/config/master.key]],
         [%w[--perms 0400 --ro-bind-data 7 /p/.env], %w[--perms 0400 --ro-bind-data 8 /p/config/master.key]]]
      )
      namespaces = stages.map { _1.argv[0..._1.argv.index("--")] }
      expect(namespaces.flatten).not_to include(File::NULL)
      expect(namespaces.flat_map { _1.each_cons(3).select { |flags| flags.first == "--ro-bind" } }.uniq)
        .to eq([%w[--ro-bind / /]])
      expect(handed.keys).to eq([5, 6, 7, 8])
      expect(handed.values.map(&:read)).to match(["", /\A\h{32}\z/, "", /\A\h{32}\z/])
    end

    it "gives the reader profile no connect-port or unix-dir flag" do
      expect(argv_of(wrapping(launcher, term, reader, trace_fd: 3))).not_to include("--connect-port", "--unix-dir")
    end

    it "turns a profile's network grants into fence flags before the separator" do
      granted = Lain::Confine::Profile.new(name: :reader, trace: false, connect_ports: [443, 80], unix_dirs: ["/run/x"])
      argv = argv_of(wrapping(launcher, term, granted, trace_fd: 3))
      expect(argv[argv.index("/f/lain-fence")..]).to eq(
        %w[/f/lain-fence --connect-port 443 --connect-port 80 --unix-dir /run/x -- cat README.md]
      )
    end

    it "binds back each read dir under /tmp after the private /tmp hides it, then masks" do
      under = Lain::Confine::Profile.reader(root: "/tmp/p", home: "/h", masks: ["/tmp/p/.env"])
      expect(argv_of(wrapping(launcher, term, under, trace_fd: 3)).each_cons(3).to_a).to include(
        %w[--tmpfs /run --unshare-pid], %w[--ro-bind-try /tmp/p /tmp/p], %w[/tmp/p --perms 0400]
      )
    end

    it "binds back a project that is /tmp itself, and a granted program under /tmp" do
      under = Lain::Confine::Profile.reader(root: "/tmp", home: "/h", exec_files: ["/tmp/x/grep"])
      expect(argv_of(wrapping(launcher, term, under, trace_fd: 3)).each_cons(3).to_a).to include(
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
      argv = argv_of(wrapping(launcher, term, workspace, trace_fd: 3))
      expect(binds_in(argv)).to eq(
        %w[--bind-try /p /p --bind-try /h/t /h/t --ro-bind /p/.envrc /p/.envrc --perms 0400 --ro-bind-data 4 /p/.env]
      )
    end

    it "binds each directory between a write and a seal over itself, so none of them can be renamed away" do
      seal = Lain::Confine::Profile::Seal
      workspace = Lain::Confine::Profile.new(
        name: :workspace, trace: false, read_dirs: ["/p"], write_dirs: %w[/p /dev/null /tmp],
        sealed: [seal.new(path: "/p/.git/worktrees/w/gitdir", absent: false),
                 seal.new(path: "/p/.git/commondir", absent: true), seal.new(path: "/elsewhere/hooks", absent: false)]
      )
      argv = argv_of(wrapping(launcher, term, workspace, trace_fd: 3))
      expect(binds_in(argv)).to eq(
        %w[--bind-try /p /p --bind-try /p/.git /p/.git --bind-try /p/.git/worktrees /p/.git/worktrees
           --bind-try /p/.git/worktrees/w /p/.git/worktrees/w
           --ro-bind /p/.git/worktrees/w/gitdir /p/.git/worktrees/w/gitdir --ro-bind /elsewhere/hooks /elsewhere/hooks]
      )
    end

    describe "a workspace with a private network" do
      def workspace(private_net) = Lain::Confine::Profile.new(name: :workspace, trace: false, private_net:)

      it "unshares bwrap's network and tells the fence the loopback is the call's own" do
        argv = argv_of(wrapping(launcher, term, workspace(true), trace_fd: 3))

        expect(argv[0...argv.index("--")]).to include("--unshare-net")
        expect(argv[argv.index("/f/lain-fence"), 2]).to eq(%w[/f/lain-fence --private-net])
      end

      it "shares the host's network otherwise, as the reader and a grant do" do
        [workspace(false), reader].each do |profile|
          expect(argv_of(wrapping(launcher, term, profile,
                                  trace_fd: 3))).not_to include("--unshare-net", "--private-net")
        end
      end
    end

    describe "a private home" do
      def home(writes = []) = Lain::Confine::Profile::PrivateHome.cargo("/h/.cargo", reads: %w[registry bin], writes:)

      def workspace(call_tmpdir: "/h/t/c", writes: [], **)
        Lain::Confine::Profile.new(name: :workspace, trace: false, read_dirs: ["/p"], homes: [home(writes)],
                                   write_dirs: ["/p", *call_tmpdir, "/h/.cargo", *writes.map { "/h/.cargo/#{_1}" },
                                                "/dev/null", "/tmp"], call_tmpdir:, **)
      end

      def mounts(profile)
        argv_of(wrapping(launcher, term, profile, trace_fd: 3)).then do |argv|
          binds_in(argv)
        end
      end

      it "mounts the call's own dir over the home, then binds back only what it names, read-only" do
        expect(mounts(workspace)).to eq(
          %w[--bind-try /p /p --bind-try /h/t/c /h/t/c --bind /h/t/c/.lain-homes/.cargo /h/.cargo
             --ro-bind-try /h/.cargo/registry /h/.cargo/registry --ro-bind-try /h/.cargo/bin /h/.cargo/bin]
        )
      end

      it "never binds the user's own home writable, though the fence lets the call write the private one" do
        argv = argv_of(wrapping(launcher, term, workspace(writes: %w[registry]), trace_fd: 3))

        expect(argv.each_cons(3).to_a).not_to include(%w[--bind-try /h/.cargo /h/.cargo])
        expect(argv[argv.index("/f/lain-fence")..]).to include("/h/.cargo")
      end

      it "binds back writable what a grant writes, after the private home is mounted" do
        mounted = mounts(workspace(writes: %w[registry .package-cache]))

        expect(mounted.each_slice(3).to_a.last(3)).to eq(
          [%w[--ro-bind-try /h/.cargo/bin /h/.cargo/bin], %w[--bind-try /h/.cargo/registry /h/.cargo/registry],
           %w[--bind-try /h/.cargo/.package-cache /h/.cargo/.package-cache]]
        )
        expect(mounted.index("/h/.cargo/registry")).to be > mounted.index("--bind")
      end

      it "mounts an empty tmpfs where the call has no dir of its own, its TMPDIR being the private /tmp" do
        expect(mounts(workspace(call_tmpdir: nil)).first(5))
          .to eq(["--bind-try", "/p", "/p", "--size", Lain::Confine::Profile::TMPFS_BYTES.to_s])
        expect(mounts(workspace(call_tmpdir: nil))[5, 2]).to eq(%w[--tmpfs /h/.cargo])
      end
    end

    describe "what a workspace hides" do
      around do |example|
        Dir.mktmpdir do |dir|
          @dir = File.realpath(dir)
          example.run
        end
      end

      def hiding(*paths)
        profile = Lain::Confine::Profile.new(name: :workspace, trace: false, hidden: paths)
        argv = argv_of(wrapping(launcher, term, profile, trace_fd: 3))
        binds_in(argv)
      end

      it "leaves out a hidden file inside a masked dir, which bwrap cannot bind into the read-only tmpfs" do
        FileUtils.mkdir_p(dir = File.join(@dir, "masked"))
        File.write(file = File.join(dir, "config"), "x")
        profile = Lain::Confine::Profile.new(name: :workspace, trace: false, masks: [dir], hidden: [file])
        argv = argv_of(wrapping(launcher, term, profile, trace_fd: 3))

        expect(binds_in(argv))
          .to eq(["--tmpfs", dir, "--remount-ro", dir])
      end

      # 0400, so an empty file over a hidden program cannot run as an empty script.
      it "shows a file empty and unrunnable and a dir empty and read-only, and skips one that has gone since" do
        File.write(file = File.join(@dir, "config"), "x")
        FileUtils.mkdir_p(dir = File.join(@dir, "shims"))

        expect(hiding(file, dir, File.join(@dir, "gone")))
          .to eq(["--perms", "0400", "--ro-bind-data", "4", file, "--tmpfs", dir, "--remount-ro", dir])
      end
    end

    describe "the seal binds, kept per seal set" do
      let(:seal) { Lain::Confine::Profile::Seal }

      def workspace(root: "/p", writes: [root, "/h/t/lain-call-1"], absent: false)
        Lain::Confine::Profile.new(
          name: :workspace, trace: false, read_dirs: [root], write_dirs: [*writes, "/dev/null", "/tmp"],
          sealed: [seal.new(path: "#{root}/.git/worktrees/w/gitdir", absent: false),
                   seal.new(path: "#{root}/.envrc", absent:)]
        )
      end

      def binds(profile) = argv_of(wrapping(launcher, term, profile, trace_fd: 3)).then { _1[0..._1.index("--")] }

      def bound(profile, flag) = binds(profile).each_cons(2).select { _1.first == flag }.map(&:last)

      it "binds each root's own seals, never those of a root it bound before" do
        binds(workspace)
        other = binds(workspace(root: "/q"))

        expect(other).to include("/q/.git/worktrees/w/gitdir", "/q/.git/worktrees", "/q/.envrc")
        expect(other.grep(%r{\A/p/})).to be_empty
      end

      it "binds a seal that has appeared since the last call, and stops binding one that has gone" do
        absent = workspace(absent: true)
        present = workspace(absent: false)

        bound = [absent, present, absent].map { |profile| bound(profile, "--ro-bind").include?("/p/.envrc") }
        expect(bound).to eq([false, true, false])
      end

      it "pins anew when a write that holds a seal changes" do
        binds(workspace)
        nearer = workspace(writes: ["/p", "/p/.git/worktrees", "/h/t/lain-call-1"])

        expect(bound(nearer, "--bind-try")).to eq(%w[/p /p/.git/worktrees /h/t/lain-call-1 /p/.git/worktrees/w])
      end
    end

    it "mounts nothing at an absent seal, so the call cannot leave a file behind there" do
      workspace = Lain::Confine::Profile.new(
        name: :workspace, trace: false, write_dirs: ["/p"],
        sealed: [Lain::Confine::Profile::Seal.new(path: "/p/.lain", absent: true)]
      )
      expect(argv_of(wrapping(launcher, term, workspace, trace_fd: 3))).not_to include("/p/.lain")
    end

    it "keeps its private /tmp when the project is elsewhere" do
      expect(argv_of(wrapping(launcher, term, reader, trace_fd: 3))).not_to include("--ro-bind-try")
    end

    it "leaves the trace out of a reader profile that has none" do
      untraced = Lain::Confine::Profile.reader(root: "/p", home: "/h", trace: false)
      expect(argv_of(wrapping(launcher, term, untraced, trace_fd: 3))).not_to include("/usr/bin/strace")
    end

    # The reaper closes every descriptor above stderr, the trace's included, so
    # the traced command cannot write its own exec lines.
    it "wraps a traced profile with strace writing to its descriptor, then the fence as a reaper only" do
      expect(argv_of(wrapping(launcher, term, Lain::Confine::Profile::TRACED, trace_fd: 5))).to eq(
        ["/usr/bin/strace", "-DD", "-f", "-s", "256", "--seccomp-bpf", "-e",
         "trace=execve,execveat,connect,sendto,sendmsg,sendmmsg", "-o", "/dev/fd/5", "--",
         "/f/lain-fence", "--reap-only", "--", "cat", "README.md"]
      )
    end

    # Tracers sharing one channel interleave their lines and lose execs.
    it "gives every stage a trace descriptor of its own, each counted up from the first" do
      piped = Lain::Shell::Term.new(pipelines: [Lain::Shell::Term.of(%w[cat f], %w[head -1]).pipelines.sole,
                                                Lain::Shell::Term.of(%w[pwd]).pipelines.sole])
      wrapped = wrapping(launcher, piped, Lain::Confine::Profile::TRACED, trace_fd: 3)

      expect(wrapped.stages.map { |stage| stage.argv[stage.argv.index("-o") + 1] }).to eq(
        ["/dev/fd/3", "/dev/fd/4", "/dev/fd/5"]
      )
      expect(wrapped.stages.map { _1.argv[(_1.argv.index("-o") + 2), 4] })
        .to all(eq(%w[-- /f/lain-fence --reap-only --]))
    end

    it "writes a reader stage's trace straight to its own descriptor" do
      piped = Lain::Shell::Term.of(%w[cat f], %w[head -1])
      wrapped = wrapping(launcher, piped, reader, trace_fd: 3)

      expect(wrapped.stages.map { |stage| stage.argv[stage.argv.index("-o") + 1] }).to eq(%w[/dev/fd/3 /dev/fd/4])
    end

    it "runs an untraced unconfined profile under the fence as a reaper only" do
      expect(argv_of(wrapping(launcher, term, Lain::Confine::Profile::NONE, trace_fd: 3)))
        .to eq(%w[/f/lain-fence --reap-only -- cat README.md])
    end

    it "prefixes every stage of every pipeline and keeps what each discards" do
      stage = ->(argv, discards = []) { Lain::Shell::Term::Stage.new(argv:, discards:) }
      piped = Lain::Shell::Term.new(pipelines: [
                                      Lain::Shell::Term::Pipeline.new(stages: [stage.call(%w[ls], [:stderr]),
                                                                               stage.call(%w[wc -l])]),
                                      Lain::Shell::Term::Pipeline.new(stages: [stage.call(%w[pwd])])
                                    ])
      wrapped = wrapping(launcher, piped, Lain::Confine::Profile::TRACED, trace_fd: 3)
      expect(wrapped.pipelines.map { |pipeline| pipeline.stages.map { [_1.argv.last(2), _1.discards] } })
        .to eq([[[%w[-- ls], [:stderr]], [%w[wc -l], []]], [[%w[-- pwd], []]]])
    end
  end

  describe Lain::Confine::Bwrap::SealBinds do
    subject(:binds) { described_class.new }

    let(:sealed) { [Lain::Confine::Profile::Seal.new(path: "/p/.git/worktrees/w/gitdir", absent: false)] }

    it "answers one frozen list for a seal set, whatever the writes that hold no seal" do
      first = binds.for(sealed, %w[/p /h/t/lain-call-1])

      expect(binds.for(sealed, %w[/p /h/t/lain-call-2])).to be(first).and be_frozen
      expect(first).to eq(%w[--bind-try /p/.git /p/.git --bind-try /p/.git/worktrees /p/.git/worktrees
                             --bind-try /p/.git/worktrees/w /p/.git/worktrees/w
                             --ro-bind /p/.git/worktrees/w/gitdir /p/.git/worktrees/w/gitdir])
    end

    it "keeps at most 64 seal sets, so the first of 65 is built again" do
      first = binds.for(sealed, %w[/p])
      64.times { |index| binds.for([Lain::Confine::Profile::Seal.new(path: "/q#{index}/.envrc", absent: false)], %w[/p]) }

      expect(binds.for(sealed, %w[/p])).to eq(first).and(satisfy { !_1.equal?(first) })
    end

    it "answers anew for another seal set or another write that holds one" do
      first = binds.for(sealed, %w[/p])
      changed = [Lain::Confine::Profile::Seal.new(path: "/p/.git/worktrees/w/gitdir", absent: true)]

      expect([binds.for(changed, %w[/p]), binds.for(sealed, %w[/p /p/.git])]).to all(satisfy { !_1.equal?(first) })
      expect(binds.for(changed, %w[/p])).not_to include("--ro-bind")
    end
  end

  describe ".fence_binary" do
    it "is the release build in the cargo target dir" do
      expect(described_class.fence_binary(env: { "CARGO_TARGET_DIR" => "/t" })).to eq("/t/release/lain-fence")
    end
  end

  describe ".on_path" do
    def executable(dir, name) = File.join(dir, name).tap { File.write(_1, "#!/bin/sh\n") }.tap { File.chmod(0o755, _1) }

    it "resolves bwrap and strace on PATH and launches the ones it found" do
      Dir.mktmpdir("lain-bwrap-path") do |dir|
        found = %w[bwrap strace].map { executable(dir, _1) }
        traced = Lain::Confine::Profile.new(name: :reader, trace: true)
        launcher = described_class.on_path(fence: "/f/lain-fence", env: { "PATH" => dir })
        argv = argv_of(wrapping(launcher, term, traced, trace_fd: 3))

        expect([argv.first, argv[argv.index("--") + 1]]).to eq(found)
      end
    end

    it "answers nil for a bwrap that is only in the cwd through an empty PATH entry" do
      Dir.mktmpdir("lain-bwrap-cwd") do |dir|
        executable(dir, "bwrap")

        launcher = Dir.chdir(dir) { described_class.on_path(fence: "/f/lain-fence", env: { "PATH" => "::" }) }

        expect(launcher.bwrap).to be_nil
      end
    end
  end

  describe "#namespace_argv" do
    it "is the namespace a confined reader call runs under, through its closing separator" do
      bare = Lain::Confine::Profile.new(name: :reader, trace: false)
      argv = argv_of(wrapping(launcher, term, bare, trace_fd: 3))

      expect(launcher.namespace_argv(private_net: false)).to eq(argv[0..argv.index("--")])
    end

    it "unshares the network only when asked to" do
      unshared = [false, true].map { launcher.namespace_argv(private_net: _1).include?("--unshare-net") }

      expect(unshared).to eq([false, true])
    end

    it "starts with the bwrap it launches" do
      expect(described_class.new(fence: "/f/lain-fence", bwrap: "/b/bwrap").namespace_argv(private_net: false).first)
        .to eq("/b/bwrap")
    end
  end

  describe "the call's view of /run" do
    let(:path_env) { { "PATH" => ENV.fetch("PATH"), "HOME" => "/h" } }

    def flags(profile, using: launcher)
      argv = argv_of(wrapping(using, term, profile))
      argv.take(argv.index("--"))
    end

    def at_runtime(dir) = described_class.on_path(fence: "/f/lain-fence", env: path_env.merge("XDG_RUNTIME_DIR" => dir))

    def present(*dirs)
      allow(File).to receive(:directory?).and_call_original
      dirs.each { allow(File).to receive(:directory?).with(_1).and_return(true) }
    end

    it "binds a NetworkManager resolv.conf read-only before the /run remount" do
      landing = "/run/NetworkManager/resolv.conf"
      argv = flags(Lain::Confine::Profile.new(name: :reader, trace: false, read_dirs: [landing]))

      expect(argv.each_cons(3).to_a).to include(["--ro-bind-try", landing, landing])
      expect(argv.index("--ro-bind-try")).to be < argv.index("--remount-ro")
      expect(argv.last(2)).to eq(%w[--remount-ro /run])
    end

    it "binds nothing under /run that the profile did not grant" do
      binds = flags(reader).each_cons(2).select { _1.first.end_with?("bind-try") && _1.last.start_with?("/run") }

      expect(binds).to eq([])
    end

    it "emits neither the tmpfs nor the remount where /run is absent" do
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with("/run").and_return(false)

      expect(flags(reader)).not_to include("/run")
    end

    it "hides the whole runtime directory outside /run, before any bind, with no lain folder yet" do
      Dir.mktmpdir("lain-runtime") do |dir|
        argv = flags(reader, using: at_runtime(dir))

        expect(argv.each_cons(2).to_a).to include(["--tmpfs", dir])
        expect(argv.index(dir)).to be < argv.index("--unshare-pid")
        expect(argv.last(4)).to eq(["--remount-ro", dir, "--remount-ro", "/run"])
      end
    end

    it "binds a grant inside a hidden runtime directory back over the mask" do
      Dir.mktmpdir("lain-runtime") do |dir|
        inner = File.join(dir, "project")
        argv = flags(Lain::Confine::Profile.new(name: :reader, trace: false, read_dirs: [inner]),
                     using: at_runtime(dir))

        expect(argv.each_cons(3).to_a).to include(["--ro-bind-try", inner, inner])
        expect(argv.index("--ro-bind-try")).to be > argv.index(dir)
      end
    end

    it "masks a runtime directory after a wider grant, which would otherwise show it again" do
      Dir.mktmpdir("lain-runtime") do |dir|
        FileUtils.mkdir_p(runtime = File.join(dir, "rt"))
        wide = Lain::Confine::Profile.new(name: :workspace, trace: false, write_dirs: [dir])
        argv = flags(wide, using: at_runtime(runtime))

        expect(argv.index(runtime)).to be > argv.index("--bind-try")
        expect(argv.last(6)).to eq(["--tmpfs", runtime, "--remount-ro", runtime, "--remount-ro", "/run"])
      end
    end

    it "makes a missing runtime directory outside the private mounts, for its owner only, and hides it" do
      Dir.mktmpdir("lain-runtime") do |dir|
        missing = File.join(dir, "rt")

        argv = flags(reader, using: at_runtime(missing))

        expect(File.stat(missing).mode & 0o777).to eq(0o700)
        expect(argv.each_cons(2).to_a).to include(["--tmpfs", missing])
      end
    end

    it "makes and hides a missing runtime directory under /tmp when the project is /tmp itself" do
      missing = "/tmp/lain-spec-#{SecureRandom.hex(4)}"
      at_tmp = Lain::Confine::Profile.reader(root: "/tmp", home: "/h")

      argv = flags(at_tmp, using: at_runtime(missing))

      expect(argv.each_cons(2).to_a).to include(["--tmpfs", missing])
    ensure
      FileUtils.rm_rf(missing)
    end

    it "names no mount for a missing runtime directory it cannot make" do
      Dir.mktmpdir("lain-runtime") do |dir|
        File.chmod(0o500, dir)
        gone = File.join(dir, "gone")

        expect(flags(reader, using: at_runtime(gone)).join(" ")).not_to include(gone)
      ensure
        File.chmod(0o700, dir)
      end
    end

    {
      "a read grant of /run/" => { read_dirs: ["/run/"] },
      "a read grant that climbs back to /run" => { read_dirs: ["/run/user/.."] },
      "a write grant of /run" => { write_dirs: ["/run"] },
      "a write grant of /" => { write_dirs: ["/"] }
    }.each do |name, grants|
      it "refuses to bind #{name}, which would restore the real /run" do
        argv = flags(Lain::Confine::Profile.new(name: :workspace, trace: false, **grants))

        expect(argv.each_cons(3).select { _1.first.end_with?("bind-try") }).to eq([])
      end
    end

    it "refuses a write grant that is a link landing inside /run" do
      Dir.mktmpdir("lain-runtime") do |dir|
        File.symlink("/run/systemd", link = File.join(dir, "link"))
        argv = flags(Lain::Confine::Profile.new(name: :workspace, trace: false, write_dirs: [link]))

        expect(argv).not_to include(link)
      end
    end

    { exec_dirs: "/run/x/bin", exec_files: "/run/x/tool", unix_dirs: "/run/x/sockets" }.each do |grant, granted|
      it "binds back what #{grant} names under /run" do
        argv = flags(Lain::Confine::Profile.new(name: :reader, trace: false, grant => [granted]))

        expect(argv.each_cons(3).to_a).to include(["--ro-bind-try", granted, granted])
      end
    end

    it "binds no seal under the private /tmp or /run that no write holds, which would show what is there" do
      seal = Lain::Confine::Profile::Seal
      profile = Lain::Confine::Profile.new(
        name: :workspace, trace: false, write_dirs: ["/p"],
        sealed: [seal.new(path: "/tmp/sockets", absent: false), seal.new(path: "/run/sockets", absent: false),
                 seal.new(path: "/p/.envrc", absent: false)]
      )

      expect(flags(profile)).not_to include("/tmp/sockets", "/run/sockets")
      expect(flags(profile).each_cons(3).to_a).to include(%w[--ro-bind /p/.envrc /p/.envrc])
    end

    it "keeps a seal under /tmp that a write holds" do
      seal = Lain::Confine::Profile::Seal
      profile = Lain::Confine::Profile.new(name: :workspace, trace: false, write_dirs: ["/tmp/p"],
                                           sealed: [seal.new(path: "/tmp/p/.envrc", absent: false)])

      expect(flags(profile).each_cons(3).to_a).to include(%w[--ro-bind /tmp/p/.envrc /tmp/p/.envrc])
    end

    it "hides a runtime directory that a wider write grant under /run would show" do
      present("/run/user/1")
      wide = Lain::Confine::Profile.new(name: :workspace, trace: false, write_dirs: ["/run/user"])

      expect(flags(wide, using: at_runtime("/run/user/1")).each_cons(2).to_a).to include(%w[--tmpfs /run/user/1])
    end

    %w[/ /tmp /run].each do |held|
      it "binds no seal at #{held}, which would restore the private mounts" do
        seal = Lain::Confine::Profile::Seal.new(path: held, absent: false)
        profile = Lain::Confine::Profile.new(name: :workspace, trace: false, write_dirs: ["/p"], sealed: [seal])

        expect(flags(profile).count("--ro-bind")).to eq(1)
      end
    end

    it "masks the runtime directory after a seal that holds it" do
      Dir.mktmpdir("lain-runtime") do |dir|
        FileUtils.mkdir_p(runtime = File.join(dir, "rt"))
        seal = Lain::Confine::Profile::Seal.new(path: dir, absent: false)
        profile = Lain::Confine::Profile.new(name: :workspace, trace: false, sealed: [seal])

        expect(flags(profile, using: at_runtime(runtime)).last(6))
          .to eq(["--tmpfs", runtime, "--remount-ro", runtime, "--remount-ro", "/run"])
      end
    end

    it "refuses a grant of a link under /tmp that lands in /run" do
      Dir.mktmpdir("l", "/tmp") do |dir|
        File.symlink("/run/systemd", link = File.join(dir, "link"))
        argv = flags(Lain::Confine::Profile.new(name: :reader, trace: false, read_dirs: [link]))

        expect(argv).not_to include(link)
      end
    end

    it "refuses a grant under /run that is a link holding /run" do
      allow(File).to receive(:realpath).and_call_original
      allow(File).to receive(:realpath).with("/run/x/link").and_return("/")
      argv = flags(Lain::Confine::Profile.new(name: :reader, trace: false, read_dirs: ["/run/x/link"]))

      expect(argv).not_to include("/run/x/link")
    end

    it "does not take a path that climbs out of /run for a grant under it" do
      climbing = "/run/../tmp/host"
      argv = flags(Lain::Confine::Profile.new(name: :reader, trace: false, read_dirs: [climbing]))

      expect(argv.join(" ")).not_to include("/tmp/host")
    end

    { "read" => :read_dirs, "write" => :write_dirs }.each do |kind, grant|
      it "refuses a #{kind} grant of the runtime directory itself" do
        Dir.mktmpdir("lain-runtime") do |dir|
          granted = Lain::Confine::Profile.new(name: :workspace, trace: false, grant => [dir])
          argv = flags(granted, using: at_runtime(dir))

          expect(argv.each_cons(3).select { _1.first.end_with?("bind-try") }).to eq([])
          expect(argv.each_cons(2).to_a).to include(["--tmpfs", dir])
        end
      end
    end

    it "refuses a grant of a link that lands inside the runtime directory" do
      Dir.mktmpdir("lain-runtime") do |dir|
        FileUtils.mkdir_p(inner = File.join(dir, "rt", "lain"))
        File.symlink(inner, link = File.join(dir, "link"))
        wide = Lain::Confine::Profile.new(name: :workspace, trace: false, write_dirs: [link])

        expect(flags(wide, using: at_runtime(File.join(dir, "rt")))).not_to include(link)
      end
    end

    it "leaves a runtime directory under the private /run or /tmp alone" do
      present("/run/user/1/lain", "/tmp/lain")

      expect(flags(reader, using: at_runtime("/run/user/1"))).not_to include("/run/user/1/lain")
      expect(flags(reader, using: at_runtime("/tmp"))).not_to include("/tmp/lain")
    end

    it "hides the /tmp fallback when the project is /tmp itself" do
      present("/tmp/lain")
      at_tmp = Lain::Confine::Profile.reader(root: "/tmp", home: "/h")

      expect(flags(at_tmp, using: at_runtime("/tmp")).each_cons(2).to_a).to include(%w[--tmpfs /tmp/lain])
    end

    it "binds nothing for a read grant of a runtime directory under /run" do
      present("/run/user/1")
      wide = Lain::Confine::Profile.new(name: :reader, trace: false, read_dirs: ["/run/user/1"])

      expect(flags(wide, using: at_runtime("/run/user/1"))).not_to include("/run/user/1")
    end
  end

  describe "the call's view of home" do
    let(:path_env) { { "PATH" => ENV.fetch("PATH") } }

    around do |example|
      Dir.mktmpdir("lain-home") do |dir|
        @home = File.realpath(dir)
        example.run
      end
    end

    def at_home(home = @home, **env)
      described_class.on_path(fence: "/f/lain-fence", env: path_env.merge("HOME" => home, **env))
    end

    def flags(profile, using: at_home)
      argv = argv_of(wrapping(using, term, profile))
      argv.take(argv.index("--"))
    end

    def under_home(*names) = names.map { File.join(@home, _1) }

    def workspace(**grants) = Lain::Confine::Profile.new(name: :workspace, trace: false, **grants)

    it "hides home behind a small tmpfs before any bind, and makes it read-only after every mount" do
      argv = flags(reader)

      expect(argv.each_cons(4).to_a).to include(["--size", Lain::Confine::Bwrap::RUN_BYTES.to_s, "--tmpfs", @home])
      expect(argv.index(@home)).to be < argv.index("--unshare-pid")
      expect(argv.last(4)).to eq(["--remount-ro", @home, "--remount-ro", "/run"])
    end

    it "binds back read-only each grant under home, before the writes" do
      read, exec, tool, sockets, project = under_home("read", "exec", "tool", "sockets", "project")
      granted = workspace(read_dirs: [read, project], exec_dirs: [exec], exec_files: [tool], unix_dirs: [sockets],
                          write_dirs: [project])
      triples = flags(granted).each_cons(3).to_a

      expect(triples).to include(*[read, exec, tool, sockets, project].map { ["--ro-bind-try", _1, _1] })
      expect(triples.index(["--ro-bind-try", project, project]))
        .to be < triples.index(["--bind-try", project, project])
    end

    it "binds a grant that lands under home where it lands, so the link to it still resolves" do
      Dir.mktmpdir("lain-elsewhere") do |elsewhere|
        FileUtils.mkdir_p(target = File.join(@home, "project"))
        File.symlink(target, link = File.join(elsewhere, "link"))

        expect(flags(workspace(read_dirs: [link])).each_cons(3).to_a).to include(["--ro-bind-try", target, target])
      end
    end

    it "binds nothing for a grant of home itself, or of a directory that holds it" do
      [@home, File.dirname(@home)].each do |wide|
        argv = flags(workspace(read_dirs: [wide], write_dirs: [wide]))

        expect(argv.each_cons(3).select { _1.first.end_with?("bind-try") }).to eq([])
      end
    end

    it "binds no seal under home that no write holds, and keeps one a write holds" do
      seal = Lain::Confine::Profile::Seal
      hooks, project = under_home("hooks", "project")
      envrc = File.join(project, ".envrc")
      sealed = workspace(write_dirs: [project],
                         sealed: [seal.new(path: hooks, absent: false), seal.new(path: envrc, absent: false)])

      argv = flags(sealed)

      expect(argv).not_to include(hooks)
      expect(argv.each_cons(3).to_a).to include(["--ro-bind", envrc, envrc])
    end

    it "leaves a missing runtime directory under home unmade, since the hidden home already covers it" do
      missing = File.join(@home, "rt")

      flags(reader, using: at_home("XDG_RUNTIME_DIR" => missing))

      expect(File).not_to exist(missing)
    end

    it "mounts nothing over a home that is absent, is /, or is under the private /tmp" do
      Dir.mktmpdir("h", "/tmp") do |under_tmp|
        ["/h-absent-#{SecureRandom.hex(4)}", "/", under_tmp].each do |home|
          expect(flags(reader, using: at_home(home)).each_cons(2).to_a).not_to include(["--tmpfs", home])
        end
      end
    end

    it "names /tmp, /run, home and the runtime directory as the roots a call cannot see" do
      expect(at_home("XDG_RUNTIME_DIR" => "/run/user/1").hidden_roots)
        .to contain_exactly("/tmp", "/run", @home, "/run/user/1")
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

    def env_reader = Lain::Confine::Profile.reader(root: project, home:, masks: [File.join(project, ".env")])

    def confined(*argv)
      plant
      run(argv_of(wrapping(described_class.new(fence:), Lain::Shell::Term.of(argv), env_reader, trace_fd: 3)))
    end

    def run(argv)
      reader, writer = IO.pipe
      out, err, status = Open3.capture3({ "LC_ALL" => "C" }, *argv, chdir: project, 3 => writer, **handed)
      [out, err, status.success?]
    ensure
      writer&.close
      reader&.close
    end

    # The private /tmp and the hidden home would hide a file there before the fence could refuse it.
    it "refuses a file outside the project" do
      skip("/var/tmp is not writable here") unless File.writable?("/var/tmp")
      Dir.mktmpdir("lain-outside", "/var/tmp") do |dir|
        File.write(outside = File.join(dir, "note"), "outside\n")

        expect(confined("cat", outside)).to match(["", /Permission denied/, false])
      end
    end

    it "reads a masked file inside the project as empty" do
      expect(confined("cat", File.join(project, ".env"))).to eq(["", "", true])
    end

    # bwrap drains a pipe and closes each descriptor it binds, so 1 shared between masks or stages would fail.
    it "binds every mask of every stage from a descriptor of its own" do
      plant
      FileUtils.mkdir_p(File.join(project, "config"))
      File.write(File.join(project, "config/master.key"), "real\n")
      profile = Lain::Confine::Profile.reader(root: project, home:, trace: false,
                                              masks: %w[.env config/master.key].map { File.join(project, _1) })
      piped = Lain::Shell::Term.of(%w[cat .env config/master.key], %w[cat config/master.key])

      outs = wrapping(described_class.new(fence:), piped, profile).stages.map { run(_1.argv) }

      expect(outs.map(&:first).uniq.sole).to match(/\A\h{32}\z/)
      expect(outs.map(&:last)).to eq([true, true])
    end

    it "leaves the contained command no descriptor beyond its own" do
      out, _, ok = confined("ls", "-l", "/proc/self/fd")
      held = out.scan(/ (\d+) -> (.*)$/).to_h

      expect([held.keys, held["3"], ok]).to match([%w[0 1 2 3], %r{\A/proc/\d+/fd\z}, true])
    end

    it "reads a masked key as empty when it is no Rails key, with no credentials beside it" do
      FileUtils.mkdir_p(File.join(project, "config"))
      File.write(key = File.join(project, "config/server.key"), "PRIVATE\n")
      profile = Lain::Confine::Profile.reader(root: project, home:, masks: [key])

      expect(run(argv_of(wrapping(described_class.new(fence:), Lain::Shell::Term.of(["cat", key]), profile))))
        .to eq(["", "", true])
    end

    describe "a Rails app's key and credentials" do
      let(:key) { SecureRandom.hex(16) }

      def plant_rails
        plant
        FileUtils.mkdir_p(File.join(project, "config"))
        File.write(File.join(project, "config/master.key"), key)
        File.write(File.join(project, "config/credentials.yml.enc"),
                   Lain::Sensitivity::RailsCredentials.seal("api: real-leaf-73\n", key:))
      end

      def read_pair(masks)
        script = "base64 -w0 config/master.key; echo; base64 -w0 config/credentials.yml.enc"
        profile = Lain::Confine::Profile.reader(root: project, home:, masks: masks.map { File.join(project, _1) })
        out, = run(argv_of(wrapping(described_class.new(fence:), Lain::Shell::Term.of(["sh", "-c", script]), profile)))
        out.lines(chomp: true).map { _1.unpack1("m") }
      end

      # A fresh ruby, so the real ActiveSupport reads the pair without its JSON extensions reaching this worker.
      def decrypted(read_key, read_credentials)
        dir = File.join(@dir, "read")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "k"), read_key)
        File.write(File.join(dir, "c"), read_credentials)
        FreshRuby.run(<<~RUBY).chomp
          require "active_support"
          require "active_support/encrypted_configuration"
          p ActiveSupport::EncryptedConfiguration.new(config_path: "#{dir}/c", key_path: "#{dir}/k",
                                                      env_key: "LAIN_SPEC_NO_KEY", raise_if_missing_key: true).config
        RUBY
      end

      it "reads as a decoy pair that decrypts to empty credentials, under a key that is not the project's" do
        plant_rails

        read_key, read_credentials = read_pair(%w[config/master.key config/credentials.yml.enc])

        expect(read_key).to match(/\A\h{32}\z/).and(satisfy { _1 != key })
        expect(decrypted(read_key, read_credentials)).to eq("{}")
      end

      it "still decrypts to empty credentials when only the key is masked" do
        plant_rails

        expect(decrypted(*read_pair(%w[config/master.key]))).to eq("{}")
      end
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
        run(argv_of(wrapping(described_class.new(fence:), Lain::Shell::Term.of(["bash", "-c", script]), profile,
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
        argv_of(wrapping(described_class.new(fence:), Lain::Shell::Term.of(argv), profile, trace_fd: 3))
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
        expect(masked_only("cat", "lkey")).to eq(["", "", true])
      end

      it "reads nothing through a link to the key file" do
        plant_repo("lkey" => File.join(ssh, "id_rsa"))
        expect(masked_only("cat", "lkey")).to eq(["", "", true])
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

    def wrapped(argv) = argv_of(wrapping(described_class.new(fence:), Lain::Shell::Term.of(argv), profile, trace_fd: 3))

    def run(argv, env: {})
      reader, writer = IO.pipe
      call_env = { "LC_ALL" => "C", "TMPDIR" => tmpdir, "GIT_CONFIG_GLOBAL" => "/dev/null", **SeedRepo::SCRUB, **env }
      out, err, status = Open3.capture3(call_env, *argv, chdir: root, 3 => writer, **handed)
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

    describe "with a fixture home and toolchain" do
      def fixture_home = File.join(@dir, "home")
      def cargo_home = File.join(fixture_home, ".cargo")
      def call_dir = File.join(tmpdir, "lain-call-1")
      def install(*parts) = File.join(fixture_home, ".local/share/mise/installs", *parts)
      def ruby_prefix = File.dirname(ruby, 2)

      def inert(path, body = "exit 0\n")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
        File.chmod(0o755, path)
      end

      def tool(*parts) = inert(install(*parts), "#!/bin/sh\necho #{parts.join("-")} ran\n")

      before do
        FileUtils.mkdir_p([File.join(cargo_home, "registry/src/x"), File.join(cargo_home, "bin"), call_dir])
        File.write(File.join(cargo_home, "registry/src/x/lib.rs"), "crate source\n")
        File.write(File.join(cargo_home, "credentials.toml"), "token = \"SECRET-MARK\"\n")
        File.write(File.join(cargo_home, ".global-cache"), "db\n")
        inert(File.join(fixture_home, ".bundle/config"), "BUNDLE_GEMS__EXAMPLE__COM: \"SECRET-MARK\"\n")
        [%w[t 1 bin tool], %w[t 1 bin other], %w[t 2 bin other], %w[u 1 bin x]].each { tool(*_1) }
        # The fixture mise sits where the profile runs programs, so only hiding it keeps it from running.
        inert(install("t", "1", "bin", "mise"))
        FileUtils.mkdir_p(File.join(fixture_home, ".local/share/mise/shims"))
        File.symlink(install("t", "1", "bin", "mise"), File.join(fixture_home, ".local/share/mise/shims/t"))
      end

      def home_profile(**changes)
        workspace = Lain::Confine::Profile.workspace(root:, home: fixture_home, tmpdir:, exec_files: [ruby])
                                          .for_call(call_dir, granted: tmpdir)
        bin = Lain::Confine::Profile.install_bin(install("t", "1", "bin", "tool"), home: fixture_home)
        workspace.with(exec_dirs: [*workspace.exec_dirs, bin], read_dirs: [*workspace.read_dirs, ruby_prefix],
                       **changes)
                 .tap do |profile|
          profile.homes.each { _1.make(profile.call_tmpdir) }
        end
      end

      def home_sh(script, **)
        term = Lain::Shell::Term.of(["sh", "-c", script])
        run(argv_of(wrapping(described_class.new(fence:), term, home_profile(**), trace_fd: 3)),
            env: { "TMPDIR" => call_dir, "RUBYOPT" => nil })
      end

      def stamp(path) = File.stat(path).then { [_1.mtime, _1.size, File.read(path)] }

      it "shows cargo's home private: the registry read-only, no credentials, and a write that misses the host" do
        kept = %w[registry/src/x/lib.rs credentials.toml .global-cache].map { File.join(cargo_home, _1) }
        before = kept.to_h { [_1, stamp(_1)] }
        out, err, = home_sh(<<~SH)
          cat #{cargo_home}/registry/src/x/lib.rs; ls -A #{cargo_home}; cat #{cargo_home}/credentials.toml
          echo planted >> #{cargo_home}/registry/src/x/lib.rs; echo made > #{cargo_home}/made && cat #{cargo_home}/made
          cat #{cargo_home}/config.toml
        SH

        expect(out.lines(chomp: true).first(5)).to eq(["crate source", "bin", "config.toml", "registry", "made"])
        expect(out).to include(%(auto-clean-frequency = "never")).and(satisfy { !_1.include?("SECRET-MARK") })
        expect(err).to match(/credentials.toml: No such file/).and match(/lib.rs: Read-only file system/)
        expect([kept.to_h { [_1, stamp(_1)] }, File.exist?(File.join(cargo_home, "made"))]).to eq([before, false])
      end

      # Bundler reads a global config only when its size is not zero, so the size is all it is shown; the fence
      # refuses the open as well, since the empty file sits at a path it does not grant.
      it "shows bundler's user config as zero bytes, refuses its content and a write, and leaves the host's alone" do
        config = File.join(fixture_home, ".bundle/config")
        before = stamp(config)

        out, err, = home_sh("stat -L -c %s #{config}; cat #{config}; echo x >> #{config}")

        expect([out, err.scan("Permission denied").size]).to eq(["0\n", 2])
        expect(stamp(config)).to eq(before)
      end

      it "runs the resolved program's own install bin, and no sibling version, other tool or project file" do
        inert(planted = File.join(root, "bin/x"))
        out, err, = home_sh([install("t", "1", "bin", "other"), install("t", "2", "bin", "other"),
                             install("u", "1", "bin", "x"), planted].join("; "))

        expect(out).to eq("t-1-bin-other ran\n")
        expect(err.scan("Permission denied").size).to eq(3)
      end

      it "never runs mise, through a shim or by name" do
        mises = [File.join(fixture_home, ".local/share/mise/shims/t"),
                 *("/usr/bin/mise" if File.exist?("/usr/bin/mise"))]

        out, err, = home_sh(mises.map { "#{_1} --version" }.join("; "))

        expect([out, err.scan(/Permission denied|not found/).size]).to eq(["", mises.size])
      end

      it "loads Ruby's resolver and reads the LSM list, but not the resolver's own dir" do
        landing = File.realpath("/etc/resolv.conf")
        upstream = Dir.glob(File.join(File.dirname(landing), "*")).find { File.file?(_1) && _1 != landing }
        script = %(#{ruby} -e 'require "resolv"; puts :resolv'; cat /sys/kernel/security/lsm)

        out, err, = home_sh(upstream ? "#{script}; cat #{upstream}" : script)

        expect(out).to start_with("resolv\n").and include("landlock")
        unread = landing.start_with?("/run/") ? /No such file or directory/ : /Permission denied/
        expect(err).to match(unread) if upstream && File.dirname(landing) != "/etc"
      end

      it "runs a real target/ and the call's own TMPDIR, never a target/ that is a link out of the root" do
        inert(File.join(root, "target/debug/build-script"), "#!/bin/sh\necho built\n")
        inert(File.join(call_dir, "test-script"), "#!/bin/sh\necho tested\n")
        out, = home_sh("#{root}/target/debug/build-script; #{call_dir}/test-script")
        FileUtils.mv(File.join(root, "target"), outside = File.join(@dir, "outside-target"))
        File.symlink(outside, File.join(root, "target"))
        linked, err, = home_sh("#{root}/target/debug/build-script")

        expect([out, linked]).to eq(["built\ntested\n", ""])
        expect(err).to match(/Permission denied|not found/)
      end

      describe "on a private network" do
        before do
          skip("this lain-fence cannot give a call a private network") unless
            Lain::Confine::Probe.new(fence:, journal: []).supports?(:private_net)
        end

        let(:net_probe) do
          <<~PY
            import socket, sys
            what = sys.argv[1]
            try:
                if what == "tcp":
                    server = socket.socket(); server.bind(("127.0.0.1", 0)); server.listen()
                    client = socket.create_connection(server.getsockname()); print("tcp ok")
                elif what == "udp":
                    socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b"x", ("127.0.0.1", 9)); print("udp ok")
                else:
                    socket.create_connection(("127.0.0.1", int(what)), timeout=2); print("host ok")
            except OSError as error:
                print(what, error.strerror)
          PY
        end

        def net(what, private_net) = home_sh(%(python3 -c '#{net_probe}' #{what}), private_net:).first

        it "binds and connects on its own loopback, still refuses a datagram, and never reaches the host's" do
          host = TCPServer.new("127.0.0.1", 0)

          expect(net("tcp", true)).to eq("tcp ok\n")
          expect(net("udp", true)).to eq("udp Operation not permitted\n")
          expect(net(host.addr[1].to_s, true)).not_to include("host ok")
        ensure
          host&.close
        end

        it "refuses a bind on the host's network, where the fence still handles TCP" do
          expect(net("tcp", false)).to eq("tcp Permission denied\n")
        end
      end

      it "keeps the toolchain and mise configs at the root read-only, and their dirs in place" do
        sealed = %w[.cargo/config.toml rust-toolchain.toml rust-toolchain .tool-versions mise.toml .mise.toml
                    .config/mise/config.toml].map { File.join(root, _1) }
        sealed.each { |path| FileUtils.mkdir_p(File.dirname(path)).then { File.write(path, "# kept\n") } }
        before = sealed.to_h { [_1, stamp(_1)] }

        _out, err, = home_sh("#{appends(sealed)}; rm #{root}/.cargo/config.toml; mv #{root}/.cargo #{root}/.cargo-old")

        expect(err.scan("Read-only file system").size).to eq(sealed.size)
        expect(err.scan(/busy/i).size).to eq(2)
        expect(sealed.to_h { [_1, stamp(_1)] }).to eq(before)
      end
    end

    # bwrap's layer alone shows the empty file, as for a reader, so the fence is not what hides the secret.
    it "shows R/.env as an empty file, so nothing of it is readable" do
      File.write(File.join(root, ".env"), "SECRET=1\n")
      full = wrapped(%w[cat .env])
      bwrap_only = full.take(full.index("--") + 1) + %w[cat .env]

      expect([run(bwrap_only), run(wrapped(%w[cat .env]))]).to eq([["", "", true]] * 2)
    end
  end
end
