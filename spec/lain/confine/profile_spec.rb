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
