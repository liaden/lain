# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Confine::MaskList do
  around do |example|
    Dir.mktmpdir("lain-mask-list") do |dir|
      @base = File.realpath(dir)
      @root = File.join(@base, "project")
      FileUtils.mkdir_p([File.join(@root, "config"), File.join(@base, "home")])
      example.run
    end
  end

  let(:root) { @root }
  let(:policy) do
    Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: File.join(@base, "home"), cwd: root))
  end
  let(:asked) { [] }
  let(:recording) do
    Class.new(SimpleDelegator) do
      def initialize(policy, asked)
        super(policy)
        @asked = asked
      end

      def mask_paths(files, **) = @asked.push(files.to_a).then { super }
    end.new(policy, asked)
  end
  let(:list) { described_class.new(root:, policy: -> { recording }) }

  def write(name, body = "x\n") = File.write(File.join(root, name), body)

  def git(*args) = SeedRepo.git(root, *args)

  def paths = list.masks.map(&:path)

  before { git("init", "-q") }

  it "masks an untracked secret at its resolved path" do
    write(".env", "A=1\n")
    write("README.md")

    expect(paths).to eq([File.join(root, ".env")])
  end

  it "masks gitignored secrets, which are the usual kind" do
    write(".gitignore", ".env\nconfig/master.key\n")
    write(".env")
    write("config/master.key")

    expect(paths).to contain_exactly(File.join(root, ".env"), File.join(root, "config", "master.key"))
  end

  it "does not look inside build and dependency directories" do
    FileUtils.mkdir_p(File.join(root, "node_modules", "pkg"))
    write(".gitignore", "node_modules/\n")
    File.write(File.join(root, "node_modules", "pkg", ".env"), "x\n")

    expect(paths).to be_empty
  end

  it "reads nothing from a directory that is not a repository" do
    write(".env")
    list = described_class.new(root: @base, policy: -> { policy })

    expect(list.masks).to be_empty
  end

  it "masks a new secret from the next ask on" do
    write("README.md")
    expect(paths).to be_empty

    write(".env.local")

    expect(paths).to eq([File.join(root, ".env.local")])
  end

  it "does not classify again when the listing is unchanged" do
    write(".env")
    list.masks
    asked.clear

    list.masks

    expect(asked).to be_empty
  end

  it "classifies only the new name when the tree changes, and keeps the earlier masks" do
    write(".env")
    list.masks
    write("notes.txt")
    asked.clear

    expect(paths).to eq([File.join(root, ".env")])
    expect(asked).to eq([["notes.txt"]])
  end

  it "drops a mask whose file is gone" do
    write(".env")
    write(".env.local")
    list.masks
    FileUtils.rm(File.join(root, ".env"))

    expect(paths).to eq([File.join(root, ".env.local")])
  end

  it "masks the landing of a link, never the link" do
    write(".env")
    File.symlink(".env", File.join(root, "settings.txt"))

    expect(paths).to eq([File.join(root, ".env")])
  end

  it "reads the policy only when first asked" do
    built = []
    lazy = described_class.new(root:, policy: -> { built.push(1).then { policy } })

    expect { lazy.masks }.to change { built.size }.from(0).to(1)
  end

  it "masks a tracked secret again when it is restored after a delete" do
    write(".env")
    git("add", ".env")
    expect(paths).to eq([File.join(root, ".env")])
    FileUtils.rm(File.join(root, ".env"))
    expect(paths).to be_empty

    write(".env")

    expect(paths).to eq([File.join(root, ".env")])
  end

  it "masks a secret at the top of a pruned directory and not below it" do
    FileUtils.mkdir_p(%w[tmp/deep vendor sub/node_modules/pkg].map { File.join(root, _1) })
    %w[tmp/.env vendor/.env sub/node_modules/.env].each { write(_1) }
    %w[tmp/deep/.env sub/node_modules/pkg/.env].each { write(_1) }

    expect(paths).to match_array(%w[tmp/.env vendor/.env sub/node_modules/.env].map { File.join(root, _1) })
  end

  describe "#prime" do
    it "leaves masks answering what an unprimed list answers" do
      write(".env")
      other = described_class.new(root:, policy: -> { policy })

      list.prime

      expect(list.masks).to eq(other.masks)
    end

    it "surfaces a failure in the background classification at masks" do
      calls = 0
      started = Queue.new
      broken = described_class.new(root:, policy: lambda {
        (calls += 1) == 1 ? raise(started.push(1) && "no policy yet") : policy
      })

      broken.prime
      started.pop

      expect { broken.masks }.to raise_error(RuntimeError, "no policy yet")
    end
  end

  # {Sensitivity::Policy#judge} is the oracle for what a refresh masks.
  describe "a refresh over links and plain files" do
    let(:home) { File.join(@base, "home") }
    let!(:policy) do
      real_home = File.join(@base, "realhome")
      FileUtils.mkdir_p(%w[.ssh .aws .kube tokens].map { File.join(real_home, _1) })
      File.write(File.join(real_home, ".ssh", "id_rsa"), "key\n")
      File.write(File.join(real_home, ".kube", "config"), "token: x\n")
      File.write(File.join(real_home, "tokens", "tokens.txt"), "t\n")
      FileUtils.rm_rf(File.join(@base, "home"))
      File.symlink(real_home, File.join(@base, "home"))
      Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, root:), home:, root:)
    end

    def plant
      stale_tracked_under_a_link
      { "key_link" => File.join(home, ".ssh", "id_rsa"), "envlink" => ".env", "linkdir" => File.join(home, ".ssh"),
        "aws" => File.join(home, ".aws", "credentials"), "shadow" => "/etc/shadow",
        "tokdir" => File.join(home, "tokens"), "readme.key" => "README.md", "kubedir" => File.join(home, ".kube") }
        .each { |name, target| File.symlink(target, File.join(root, name)) }
      write(".env", "A=1\n")
      write("README.md")
    end

    def stale_tracked_under_a_link
      %w[linkdir/id_rsa kubedir/config].each do |name|
        FileUtils.mkdir_p(File.dirname(File.join(root, name)))
        write(name)
        git("add", name)
      end
      FileUtils.rm_r(%w[linkdir kubedir].map { File.join(root, _1) })
    end

    def plain_files
      Array.new(200) { |i| "d#{i % 10}/f#{i}.txt" }.each do |name|
        FileUtils.mkdir_p(File.dirname(File.join(root, name)))
        write(name)
      end
    end

    def judged(names)
      masks = names.filter_map do |name|
        verdict = policy.judge(name, cwd: root)
        Lain::Sensitivity::Policy.masks?(verdict) ? [File.realpath(name, root), verdict.reason] : nil
      rescue SystemCallError
        nil
      end
      masks.uniq(&:first).select { File.exist?(_1.first) }
    end

    it "masks what judge masks, name by name" do
      plant
      git("add", *plain_files.first(100))
      listed = git("ls-files", "-z", "-co").stdout.split("\0").uniq

      expect(listed).to include("linkdir/id_rsa", "kubedir/config", "linkdir", "d0/f0.txt", "d9/f199.txt")
      expect(judged(listed).map(&:first))
        .to include(File.join(root, ".env"), File.join(@base, "realhome", ".ssh", "id_rsa"))
      expect(list.masks.map { [_1.path, _1.reason] }).to match_array(judged(listed))
    end

    def swap_for_link(name, target)
      FileUtils.rm(File.join(root, name))
      File.symlink(target, File.join(root, name))
    end

    it "masks a listed file on the next refresh once it is swapped for a link to a secret" do
      write("plain.txt")
      expect(paths).to be_empty

      swap_for_link("plain.txt", File.join(home, ".ssh", "id_rsa"))

      expect(list.masks.map { [_1.path, _1.reason] }).to eq(judged(["plain.txt"]))
      expect(paths).to eq([File.join(@base, "realhome", ".ssh", "id_rsa")])
    end

    it "unmasks a listed link once it is swapped back for a plain file" do
      File.symlink(File.join(home, ".ssh", "id_rsa"), File.join(root, "plain.txt"))
      expect(paths).to eq([File.join(@base, "realhome", ".ssh", "id_rsa")])

      FileUtils.rm(File.join(root, "plain.txt"))
      write("plain.txt")

      expect(paths).to be_empty
    end

    it "judges no name again when 200 listed files are unchanged" do
      plain_files
      list.masks
      asked.clear

      list.masks

      expect(asked).to be_empty
    end

    def secret = File.join(@base, "realhome", ".ssh", "id_rsa")

    def notes = File.join(@base, "realhome", "notes.txt").tap { File.write(_1, "n\n") }

    it "masks a listed link retargeted at a secret by a delete and a new link" do
      File.symlink(notes, File.join(root, "lnk"))
      expect(paths).to be_empty

      swap_for_link("lnk", File.join(home, ".ssh", "id_rsa"))

      expect(paths).to eq([secret])
    end

    it "masks a listed link retargeted at a secret in place" do
      File.symlink(notes, File.join(root, "lnk"))
      expect(paths).to be_empty

      system("ln", "-sfn", File.join(home, ".ssh", "id_rsa"), File.join(root, "lnk"), exception: true)

      expect(paths).to eq([secret])
    end

    it "unmasks a listed link whose target outside the tree is deleted" do
      File.symlink(File.join(home, "tokens", "tokens.txt"), File.join(root, "k"))
      expect(paths).to eq([File.join(@base, "realhome", "tokens", "tokens.txt")])

      FileUtils.rm(File.join(home, "tokens", "tokens.txt"))

      expect(paths).to be_empty
    end

    it "unmasks a secret link moved out of the tree while its landing remains" do
      File.symlink(File.join(home, ".ssh", "id_rsa"), File.join(root, "k"))
      expect(paths).to eq([secret])

      File.rename(File.join(root, "k"), File.join(@base, "k"))

      expect(paths).to be_empty
    end

    it "masks a tracked name at its new landing once its directory is swapped for a link" do
      FileUtils.mkdir_p(File.join(root, "d"))
      write("d/id_rsa")
      git("add", "d/id_rsa")
      expect(paths).to eq([File.join(root, "d", "id_rsa")])

      FileUtils.rm_r(File.join(root, "d"))
      File.symlink(File.join(home, ".ssh"), File.join(root, "d"))

      expect(paths).to include(secret)
    end

    it "keeps the masks it has when a listing fails" do
      failing = false
      shell_out = lambda do |*argv, **opts|
        failing ? Lain::Shell::Out.new("false", **opts.slice(:chdir, :timeout)) : Lain::Shell::Out.new(*argv, **opts)
      end
      flaky = described_class.new(root:, policy: -> { policy }, shell_out:)
      File.symlink(File.join(home, ".ssh", "id_rsa"), File.join(root, "k"))
      expect(flaky.masks.map(&:path)).to eq([secret])

      failing = true

      expect(flaky.masks.map(&:path)).to eq([secret])
    end
  end
end
