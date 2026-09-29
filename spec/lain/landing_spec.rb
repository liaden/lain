# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Landing do
  around do |example|
    Dir.mktmpdir("lain-landing") do |dir|
      @base = File.realpath(dir)
      @root = File.join(@base, "repo")
      FileUtils.mkdir_p(@root)
      example.run
    end
  end

  def real(*parts) = File.join(@base, *parts)

  it "answers the real path a link points at" do
    File.write(File.join(@root, ".netrc"), "machine x\n")
    File.symlink(".netrc", File.join(@root, "plain.txt"))

    expect(described_class.of("plain.txt", cwd: @root).first).to eq(File.join(@root, ".netrc"))
  end

  it "lands a missing path under the real path of its longest existing prefix" do
    FileUtils.mkdir_p(real("elsewhere"))
    File.symlink(real("elsewhere"), File.join(@root, "dir"))

    expect(described_class.of("dir/new.txt", cwd: @root).first).to eq(real("elsewhere", "new.txt"))
  end

  it "cleans only after resolving, so link/.. is the link target's parent" do
    FileUtils.mkdir_p(real("elsewhere", "deep"))
    File.symlink(real("elsewhere", "deep"), File.join(@root, "link"))

    expect(described_class.of("link/../x", cwd: @root).first).to eq(real("elsewhere", "x"))
  end

  it "refuses a dangling link by name" do
    File.symlink("missing", File.join(@root, "gone"))

    expect { described_class.of("gone", cwd: @root) }
      .to raise_error(described_class::Dangling, /gone/)
  end

  it "takes an absolute path as written" do
    expect(described_class.of(File.join(@root, "a.txt"), cwd: "/nowhere").first).to eq(File.join(@root, "a.txt"))
  end

  it "also spells the landing under the lexical home when home is a link" do
    FileUtils.mkdir_p(real("realhome", ".kube"))
    File.write(real("realhome", ".kube", "config"), "x")
    File.symlink(real("realhome"), real("home"))
    File.symlink(real("home", ".kube", "config"), File.join(@root, "k"))

    spellings = described_class.of("k", cwd: @root, home: real("home"))

    expect(spellings).to eq([real("realhome", ".kube", "config"), real("home", ".kube", "config")])
  end

  it "also spells the landing under the lexical root when the root is a link" do
    FileUtils.mkdir_p(real("realrepo"))
    File.write(real("realrepo", "a.txt"), "x")
    File.symlink(real("realrepo"), real("linkrepo"))

    spellings = described_class.of("a.txt", cwd: real("linkrepo"), root: real("linkrepo"))

    expect(spellings).to eq([real("realrepo", "a.txt"), real("linkrepo", "a.txt")])
  end

  it "adds no respelling when the lexical anchors are already real" do
    File.write(File.join(@root, "a"), "x")

    expect(described_class.of("a", cwd: @root, home: real("home"), root: @root))
      .to eq([File.join(@root, "a")])
  end
end
