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
end
