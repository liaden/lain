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
