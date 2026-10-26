# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Confine::Profile do
  describe ".reader" do
    subject(:profile) do
      described_class.reader(root: "/p", home: "/h", masks: ["/p/.env"], exec_files: ["/h/.local/bin/grep"])
    end

    it "runs only system programs, rustup's toolchains and the files it was granted" do
      expect([profile.name, profile.exec_dirs,
              profile.exec_files]).to eq([:reader, %w[/usr /h/.rustup/toolchains], ["/h/.local/bin/grep"]])
    end

    it "reads the project, the system and the home toolchains a version probe needs" do
      expect(profile.read_dirs).to eq(
        %w[/p /usr /etc /proc /dev/null /dev/urandom /tmp
           /h/.rustup /h/.cargo/bin /h/.config/git /h/.gitconfig /h/.local/share/mise/installs]
      )
    end

    it "writes nowhere but /dev/null and its own private /tmp, and masks what it was handed" do
      expect([profile.write_dirs, profile.masks]).to eq([%w[/dev/null /tmp], ["/p/.env"]])
    end

    it "refuses a relative path, which the fence would resolve against whatever cwd it runs in" do
      expect { described_class.reader(root: "p", home: "/h") }.to raise_error(ArgumentError, /"p"/)
    end

    it "grants no network" do
      expect([profile.connect_ports, profile.unix_dirs]).to eq([[], []])
    end

    it "carries the connect ports and unix dirs it was built with" do
      granted = described_class.new(name: :reader, trace: false, connect_ports: [443, 80], unix_dirs: ["/run/x"])
      expect([granted.connect_ports, granted.unix_dirs]).to eq([[443, 80], ["/run/x"]])
    end

    it "refuses a port outside 1 to 65535 or one that is not an integer" do
      [0, 70_000, "443"].each do |port|
        expect { described_class.new(name: :reader, trace: false, connect_ports: [port]) }
          .to raise_error(ArgumentError, /port/)
      end
    end

    it "refuses a relative unix dir" do
      expect { described_class.new(name: :reader, trace: false, unix_dirs: ["run/x"]) }
        .to raise_error(ArgumentError, %r{"run/x"})
    end

    it "is traced and sizes its /tmp" do
      expect([profile.trace, profile.tmpfs_bytes]).to eq([true, described_class::TMPFS_BYTES])
    end

    it "drops the trace when told to" do
      expect(described_class.reader(root: "/p", home: "/h", trace: false).trace).to be(false)
    end

    it "is confined" do
      expect(profile).to be_confined
    end

    it "is deeply frozen" do
      expect(profile).to be_deeply_frozen
    end

    it "reads the main checkout's git dir from a linked worktree, which git needs to run at all" do
      Dir.mktmpdir do |dir|
        common = File.join(dir, "main", ".git")
        admin = File.join(common, "worktrees", "w")
        FileUtils.mkdir_p(admin)
        File.write(File.join(admin, "commondir"), "../..\n")
        root = FileUtils.mkdir_p(File.join(dir, "w")).first
        File.write(File.join(root, ".git"), "gitdir: #{admin}\n")

        expect(described_class.reader(root:, home: "/h").read_dirs).to include(common)
      end
    end

    it "reads the project where it lands, so a linked root is bound where bwrap can see it" do
      Dir.mktmpdir do |dir|
        File.symlink(dir, link = "#{dir}-link")
        expect(described_class.reader(root: link, home: "/h").read_dirs.first).to eq(File.realpath(dir))
      ensure
        FileUtils.rm_f(link)
      end
    end

    it "adds no git dir for an ordinary checkout, whose own .git is under the project" do
      Dir.mktmpdir do |root|
        Dir.mkdir(File.join(root, ".git"))
        expect(described_class.reader(root:, home: "/h").read_dirs.first(2)).to eq([root, "/usr"])
      end
    end
  end

  describe ".workspace" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = File.realpath(dir)
        example.run
      end
    end

    def root = File.join(@dir, "r")
    def tmpdir = File.join(@dir, "t")
    def common = File.join(@dir, "main", ".git")
    def sealed_of(profile) = profile.sealed.to_h { [_1.path, _1.absent] }

    def workspace(at = root, tmp: tmpdir, **)
      described_class.workspace(root: at, home: "/h", tmpdir: tmp, masks: ["#{at}/.env"], **)
    end

    def linked_worktree
      main = File.dirname(common)
      FileUtils.mkdir_p(main)
      SeedRepo.git(main, "init", "-q")
      SeedRepo.git(main, "-c", "user.name=a", "-c", "user.email=a@b", "commit", "-q", "--allow-empty", "-m", "i")
      SeedRepo.git(main, "worktree", "add", "-q", root)
    end

    context "with an ordinary checkout" do
      before do
        FileUtils.mkdir_p(root)
        SeedRepo.git(root, "init", "-q")
      end

      it "writes the project, its TMPDIR, /dev/null and its private /tmp" do
        expect(workspace.write_dirs).to eq([root, tmpdir, "/dev/null", "/tmp"])
      end

      it "reads and runs what a reader does, and masks what it was handed" do
        reader = described_class.reader(root:, home: "/h", masks: ["#{root}/.env"])
        expect([workspace.name, workspace.exec_dirs, workspace.read_dirs, workspace.masks])
          .to eq([:workspace, reader.exec_dirs, reader.read_dirs, reader.masks])
      end

      it "grants no network, is traced, confined and deeply frozen" do
        expect([workspace.connect_ports, workspace.unix_dirs, workspace.trace]).to eq([[], [], true])
        expect(workspace).to be_confined.and be_deeply_frozen
      end

      it "seals the hooks, the configs, what redirects git and the project's persistence files" do
        git = File.join(root, ".git")
        expect(sealed_of(workspace)).to eq(
          File.join(git, "hooks") => false, File.join(git, "config") => false,
          File.join(git, "config.worktree") => true, File.join(git, "commondir") => true,
          File.join(git, "modules") => true, File.join(git, "worktrees") => true,
          File.join(root, ".lain") => true, File.join(root, ".envrc") => true,
          File.join(root, ".pre-commit-config.yaml") => true
        )
      end

      it "seals the submodules' git dirs and every worktree's admin dir, each whole" do
        FileUtils.mkdir_p(File.join(root, ".git", "modules", "sub"))
        SeedRepo.git(root, "-c", "user.name=a", "-c", "user.email=a@b", "commit", "-q", "--allow-empty", "-m", "i")
        SeedRepo.git(root, "worktree", "add", "-q", File.join(@dir, "w2"))
        expect(sealed_of(workspace)).to include(
          File.join(root, ".git", "modules") => false, File.join(root, ".git", "worktrees") => false
        )
      end

      it "seals the whole git dir, so a commit fails, when git cannot answer for it" do
        File.write(File.join(root, ".git", "HEAD"), "not a ref\n")
        expect(sealed_of(workspace)).to eq(
          File.join(root, ".git") => false, File.join(root, ".lain") => true, File.join(root, ".envrc") => true,
          File.join(root, ".pre-commit-config.yaml") => true
        )
      end

      it "refuses a seal reached through a link inside the project, which the call could repoint" do
        FileUtils.mkdir_p(File.join(root, "real-hooks"))
        File.symlink(File.join(root, "real-hooks"), File.join(root, ".husky"))
        SeedRepo.git(root, "config", "core.hooksPath", ".husky")
        expect { workspace }.to raise_error(described_class::Unsealable, /#{Regexp.escape(File.join(root, ".husky"))}/)
      end

      it "refuses a persistence file that is a link" do
        File.write(File.join(root, "kept"), "x\n")
        File.symlink("kept", File.join(root, ".envrc"))
        expect { workspace }.to raise_error(described_class::Unsealable, /\.envrc/)
      end

      it "seals a hooks dir once when two names resolve to it" do
        File.symlink(File.join(root, ".git", "hooks"), link = File.join(@dir, "hooks-link"))
        SeedRepo.git(root, "config", "core.hooksPath", link)
        expect(workspace.sealed.count { _1.path == File.join(root, ".git", "hooks") }).to eq(1)
      end

      it "lists each absent persistence file as absent, and a present one as present" do
        File.write(File.join(root, ".envrc"), "export X=1\n")
        expect(sealed_of(workspace).slice(*%w[.lain .envrc .pre-commit-config.yaml].map { File.join(root, _1) }))
          .to eq(File.join(root, ".lain") => true, File.join(root, ".envrc") => false,
                 File.join(root, ".pre-commit-config.yaml") => true)
      end

      it "resolves a relative dangling link where its parent really is, not where the path spells it" do
        FileUtils.mkdir_p([real = File.join(@dir, "b", "real"), File.join(@dir, "a")])
        File.symlink(real, spelled = File.join(@dir, "a", "parent"))
        File.symlink("../gone", File.join(real, "hooks"))
        SeedRepo.git(root, "config", "core.hooksPath", File.join(spelled, "hooks"))

        expect(sealed_of(workspace)).to include(File.join(@dir, "b", "gone") => true)
        expect(sealed_of(workspace)).not_to include(File.join(@dir, "a", "gone"))
      end

      it "seals a core.hooksPath directory" do
        SeedRepo.git(root, "config", "core.hooksPath", ".husky")
        FileUtils.mkdir_p(File.join(root, ".husky"))
        expect(sealed_of(workspace))
          .to include(File.join(root, ".husky") => false, File.join(root, ".git", "hooks") => false)
      end
    end

    context "with a linked worktree" do
      before { linked_worktree }

      let(:admin) { File.join(common, "worktrees", "r") }

      it "writes what a commit needs in the common dir, and the worktree's own admin dir, but not the main index" do
        expect(workspace.write_dirs).to eq(
          [root, tmpdir, *%w[objects refs logs].map { File.join(common, _1) }, admin, "/dev/null", "/tmp"]
        )
      end

      it "seals the common dir's hooks and config, the worktree's own config, and every pointer between them" do
        expect(sealed_of(workspace)).to include(
          File.join(common, "hooks") => false, File.join(common, "config") => false,
          File.join(admin, "config.worktree") => true, File.join(root, ".git") => false,
          File.join(admin, "commondir") => false, File.join(admin, "gitdir") => false
        )
      end

      it "seals a dangling link outside the writes where it lands, absent there" do
        hooks = File.join(common, "hooks")
        FileUtils.rm_rf(hooks)
        File.symlink(gone = File.join(@dir, "gone"), hooks)

        expect(sealed_of(workspace)).to include(gone => true)
        expect(sealed_of(workspace)).not_to include(hooks)
        expect(workspace.sealed.find { _1.path == gone }.hops).to eq([hooks])
      end
    end

    it "writes the common index too when the git dir is the common dir, as a separate git dir is" do
      FileUtils.mkdir_p([root, File.dirname(common)])
      SeedRepo.git(root, "init", "-q", "--separate-git-dir", common)
      expect(workspace.write_dirs).to include(File.join(common, "index"), common)
    end

    it "seals only the project's persistence files outside a git checkout" do
      FileUtils.mkdir_p(root)
      expect(sealed_of(workspace).keys).to eq(%w[.lain .envrc .pre-commit-config.yaml].map { File.join(root, _1) })
    end

    it "refuses a relative TMPDIR" do
      FileUtils.mkdir_p(root)
      expect { workspace(tmp: "t") }.to raise_error(ArgumentError, /"t"/)
    end

    it "refuses a TMPDIR that is home or holds it, which would make home writable" do
      FileUtils.mkdir_p([root, File.join(@dir, "h")])
      [File.join(@dir, "h"), @dir].each do |tmp|
        expect { described_class.workspace(root:, home: File.join(@dir, "h"), tmpdir: tmp) }
          .to raise_error(ArgumentError, /home/)
      end
    end

    it "refuses a root with a newline in it, which would split git's answer" do
      FileUtils.mkdir_p(bent = File.join(@dir, "r\nx"))
      expect { workspace(bent) }.to raise_error(ArgumentError, /newline/)
    end

    describe "#for_call" do
      before { FileUtils.mkdir_p(root) }

      let(:call_dir) { File.join(tmpdir, "lain-call-1") }

      it "writes the call's own dir in place of the TMPDIR, and names it" do
        moved = workspace.for_call(call_dir, granted: tmpdir)

        expect([moved.write_dirs, moved.call_tmpdir]).to eq([[root, call_dir, "/dev/null", "/tmp"], call_dir])
      end

      it "keeps the call's dir through a later change to another grant" do
        expect(workspace.for_call(call_dir, granted: tmpdir).with(connect_ports: [8080]).call_tmpdir).to eq(call_dir)
      end

      it "refuses a dir that is not beneath the TMPDIR the profile writes" do
        [tmpdir, File.join(@dir, "elsewhere")].each do |dir|
          expect { workspace.for_call(dir, granted: tmpdir) }.to raise_error(ArgumentError, /beneath/)
        end
      end

      it "refuses to move the private /tmp, which is already the call's own" do
        expect { workspace(tmp: "/tmp").for_call("/tmp/lain-call-1", granted: "/tmp") }
          .to raise_error(ArgumentError, %r{/tmp})
      end

      it "refuses a TMPDIR the profile does not write" do
        other = File.join(@dir, "u")
        expect { workspace.for_call(File.join(other, "x"), granted: other) }.to raise_error(ArgumentError, /writes/)
      end
    end

    it "names no call dir of its own, so nothing removes the TMPDIR it was built with" do
      FileUtils.mkdir_p(root)
      expect([workspace, described_class::TRACED, described_class.reader(root:, home: "/h")].map(&:call_tmpdir))
        .to eq([nil, nil, nil])
    end
  end

  describe ".grant" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = File.realpath(dir)
        FileUtils.mkdir_p([root, home, *%w[bin specifications].map { File.join(gem_home, _1) },
                           File.join(root, "target")])
        SeedRepo.git(root, "init", "-q")
        example.run
      end
    end

    def root = File.join(@dir, "r")
    def home = File.join(@dir, "h")
    def tmpdir = File.join(@dir, "t")
    def gem_home = File.join(@dir, "gems")
    def env = { "GEM_HOME" => gem_home }

    def grant(program, env: self.env, **)
      described_class.grant(program:, root:, home:, tmpdir:, env:, masks: ["#{root}/.env"], **)
    end

    def workspace = described_class.workspace(root:, home:, tmpdir:, masks: ["#{root}/.env"])

    def refused?(profile) = profile.name == :workspace && profile.connect_ports.empty? && profile == workspace

    it "is confined and named :grant" do
      expect([described_class.confines?(:grant), grant("git").name, grant("git").confined?]).to eq([true, :grant, true])
    end

    it "keeps everything the workspace profile seals, reads, runs, writes and masks" do
      %w[bundle cargo git].each do |program|
        granted = grant(program)

        expect(granted.sealed).to include(*workspace.sealed)
        given = [granted.exec_dirs, granted.read_dirs, granted.write_dirs]
        kept = [workspace.exec_dirs, workspace.read_dirs, workspace.write_dirs]
        expect(given.zip(kept)).to all(satisfy { |grants, workspaces| (workspaces - grants).empty? })
        expect([granted.masks, granted.trace, granted.read_dirs.first]).to eq([workspace.masks, true, root])
      end
    end

    it "gives bundle ports 443 and 80, cargo and git 443, each the resolver's socket dir" do
      expect(%w[bundle cargo git].map { [grant(_1).connect_ports, grant(_1).unix_dirs] })
        .to eq([[[443, 80], [described_class::RESOLVER]], [[443], [described_class::RESOLVER]],
                [[443], [described_class::RESOLVER]]])
      expect(described_class::RESOLVER).to eq("/run/systemd/resolve")
    end

    it "reads the resolver's dir, so nss-resolve can find its socket" do
      expect(grant("git").read_dirs).to include(described_class::RESOLVER)
    end

    it "writes the gem home the env names and bundler's user cache under home, only for bundle" do
      bundled = [gem_home, File.join(home, ".bundle", "cache")]

      expect(grant("bundle").write_dirs).to include(*bundled)
      expect([grant("cargo").write_dirs, grant("git").write_dirs, workspace.write_dirs])
        .to all(satisfy { !_1.intersect?(bundled) })
    end

    it "reads GEM_HOME and CARGO_HOME, which a child keeps, and no BUNDLE_USER_ name, which it does not" do
      kept = %w[GEM_HOME CARGO_HOME BUNDLE_USER_CACHE BUNDLE_USER_HOME].map { Lain::Exec::ChildEnv::KEEP.match?(_1) }
      cache = File.join(@dir, "cache")

      expect(kept).to eq([true, true, false, false])
      expect(grant("bundle", env: env.merge("BUNDLE_USER_CACHE" => cache, "BUNDLE_USER_HOME" => cache)).write_dirs)
        .to include(File.join(home, ".bundle", "cache")).and(satisfy { _1.none? { |dir| dir.start_with?(cache) } })
    end

    it "takes the gem home a child's bundler finds with no GEM_HOME: RubyGems' default dir" do
      expect(grant("bundle", env: {}).write_dirs).to include(Gem.default_dir)
    end

    it "never writes the dir RubyGems installs executables to, and seals it when it sits in the gem home" do
      bindir = File.join(gem_home, "bin")
      [{}, env].each do |given|
        granted = grant("bundle", env: given)
        installs = Gem.bindir(given.fetch("GEM_HOME", Gem.default_dir))
        writable = granted.write_dirs.any? { Lain::Landing.under?(installs, _1) }

        expect(!writable || granted.sealed.any? { _1.path == installs && !_1.absent }).to be(true), installs
      end
      expect(grant("bundle").sealed.map(&:path)).to include(bindir)
    end

    it "grants bundle nothing when the executables dir would sit in the gem home and is absent" do
      FileUtils.rm_rf(File.join(gem_home, "bin"))

      expect(refused?(grant("bundle"))).to be(true)
    end

    { "home" => -> { home }, "/" => -> { "/" }, "above home" => -> { "#{home}/.." },
      "a relative path" => -> { "gems" } }.each do |what, dir|
      it "grants bundle nothing for a GEM_HOME that is #{what}" do
        expect(refused?(grant("bundle", env: { "GEM_HOME" => instance_exec(&dir) }))).to be(true)
      end

      it "grants cargo nothing for a CARGO_HOME that is #{what}" do
        expect(refused?(grant("cargo", env: { "CARGO_HOME" => instance_exec(&dir) }))).to be(true)
      end
    end

    it "grants nothing for a gem home or cargo home that lands somewhere other than it claims" do
      File.symlink(gem_home, linked = File.join(@dir, "linked"))

      expect([grant("bundle", env: { "GEM_HOME" => linked }), grant("cargo", env: { "CARGO_HOME" => linked })])
        .to all(satisfy { refused?(_1) })
    end

    it "writes cargo's registry, git checkouts and package lock, never the rest of ~/.cargo, and runs target/" do
      cargo = grant("cargo")

      expect(cargo.write_dirs).to include(*%w[registry git .package-cache].map { File.join(home, ".cargo", _1) })
      expect(cargo.write_dirs).not_to include(File.join(home, ".cargo"), File.join(home, ".cargo", "bin"))
      expect(cargo.exec_dirs).to include(File.join(root, "target"))
      expect([grant("bundle").exec_dirs, grant("git").exec_dirs]).to all(eq(workspace.exec_dirs))
    end

    it "writes beneath the CARGO_HOME the env names" do
      cargo_home = File.join(@dir, "cargo-home").tap { FileUtils.mkdir_p(_1) }

      expect(grant("cargo", env: { "CARGO_HOME" => cargo_home }).write_dirs)
        .to include(*%w[registry git .package-cache].map { File.join(cargo_home, _1) })
    end

    it "grants cargo nothing when target/ is a link out of the project, or is not a directory" do
      FileUtils.rm_rf(target = File.join(root, "target"))
      File.symlink(FileUtils.mkdir_p(File.join(@dir, "outside")).first, target)
      linked = grant("cargo")
      File.unlink(target)
      File.write(target, "")

      expect([linked, grant("cargo")]).to all(satisfy { refused?(_1) })
    end

    it "grants a first cargo fetch in a checkout with no target/ yet, with no exec dir" do
      FileUtils.rm_rf(File.join(root, "target"))
      fetch = grant("cargo")

      expect([fetch.name, fetch.connect_ports, fetch.exec_dirs]).to eq([:grant, [443], workspace.exec_dirs])
    end

    it "grants bundle nothing for a GEM_HOME without RubyGems' layout, a specifications dir" do
      FileUtils.rm_rf(File.join(gem_home, "specifications"))

      expect(refused?(grant("bundle"))).to be(true)
    end

    describe "a gem home or cargo home under home that holds more than its own" do
      def project = File.join(home, "dev", "r")

      before do
        FileUtils.mkdir_p(project)
        SeedRepo.git(project, "init", "-q")
      end

      def grant_in_home(program, key, dir)
        FileUtils.mkdir_p(%w[bin specifications].map { File.join(dir, _1) })
        described_class.grant(program:, root: project, home:, tmpdir:, env: { key => dir })
      end

      { "~/.local, which holds the mise installs" => ".local", "~/dev, which holds the project" => "dev",
        "~/.config, which holds git's config" => ".config" }.each do |what, name|
        it "grants nothing for a GEM_HOME or CARGO_HOME of #{what}" do
          if name == ".local"
            FileUtils.mkdir_p(File.join(home, ".local/share/mise/installs"))
          elsif name == ".config"
            FileUtils.mkdir_p(File.join(home, ".config/git"))
          end
          dir = File.join(home, name)
          refused = [grant_in_home("bundle", "GEM_HOME", dir), grant_in_home("cargo", "CARGO_HOME", dir)]

          expect(refused.map { [_1.name, _1.connect_ports] }).to eq([[:workspace, []], [:workspace, []]])
        end
      end

      it "still grants cargo the default ~/.cargo, though it holds the bin a reader may run" do
        FileUtils.mkdir_p(File.join(home, ".cargo/bin"))
        FileUtils.mkdir_p(File.join(project, "target"))

        expect(described_class.grant(program: "cargo", root: project, home:, tmpdir:, env: {}).name).to eq(:grant)
      end
    end

    it "is deeply frozen" do
      expect(grant("bundle")).to be_deeply_frozen
    end

    it "refuses a program it holds no grant for" do
      expect { grant("npm") }.to raise_error(ArgumentError, /npm/)
    end

    it "keeps the grant through the call's own TMPDIR" do
      call_dir = File.join(tmpdir, "lain-call-1")
      moved = grant("bundle").for_call(call_dir, granted: tmpdir)

      expect([moved.name, moved.call_tmpdir, moved.connect_ports]).to eq([:grant, call_dir, [443, 80]])
      expect(moved.write_dirs).to include(gem_home)
    end
  end

  describe "#runs?" do
    subject(:profile) { described_class.reader(root: "/p", home: "/h", exec_files: ["/h/.local/bin/grep"]) }

    it "runs a program beneath an exec dir, or one granted by name" do
      expect([profile.runs?("/usr/bin/cat"), profile.runs?("/h/.local/bin/grep")]).to eq([true, true])
    end

    it "runs nothing else, and a dir's name is not a prefix of its neighbour's" do
      expect([profile.runs?("/p/bin/cat"), profile.runs?("/usrx/bin/cat"), profile.runs?("/h/.local/bin/rg")])
        .to eq([false, false, false])
    end
  end

  describe "NONE" do
    it "is neither traced nor confined" do
      expect([described_class::NONE.name, described_class::NONE.trace, described_class::NONE.confined?])
        .to eq([:none, false, false])
    end
  end

  describe "TRACED" do
    it "is traced and not confined" do
      expect([described_class::TRACED.name, described_class::TRACED.trace, described_class::TRACED.confined?])
        .to eq([:traced, true, false])
    end
  end
end
