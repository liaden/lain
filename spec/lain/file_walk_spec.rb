# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"

RSpec.describe Lain::FileWalk do
  subject(:walk) { described_class.new(root:) }

  let(:root) { @root }
  let(:failing_consumer) { proc { |_path| raise Errno::EPIPE } }

  around do |example|
    Dir.mktmpdir("lain-file-walk") { |made| @root = File.realpath(made) and example.run }
  end

  def write(relative, body = "x\n")
    File.join(root, relative).tap do |path|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end
  end

  def git(*argv, chdir: root)
    _out, err, status = Open3.capture3("git", *argv, chdir:)
    raise err unless status.success?
  end

  def init_repo(relative = ".")
    dir = File.join(root, relative)
    FileUtils.mkdir_p(dir)
    git("init", "-q", chdir: dir)
    dir
  end

  def relatives = walk.map { _1.delete_prefix("#{root}/") }

  it "lists tracked and untracked files of a repository, not ignored ones" do
    init_repo
    write(".gitignore", "target/\n")
    write("tracked.rb")
    git("add", "tracked.rb")
    write("untracked.rb")
    3.times { write("target/out#{_1}.o") }

    expect(relatives).to contain_exactly(".gitignore", "tracked.rb", "untracked.rb")
  end

  it "honors the ignores of a repository held by a plain parent" do
    write("notes.txt")
    init_repo("app")
    write("app/.gitignore", "target/\n")
    write("app/main.rb")
    50.times { write("app/target/f#{_1}.o") }

    expect(relatives).to contain_exactly("notes.txt", "app/.gitignore", "app/main.rb")
  end

  it "honors a nested repository inside a repository" do
    init_repo
    init_repo("inner")
    write("inner/.gitignore", "build/\n")
    write("inner/lib.rb")
    write("inner/build/junk.o")

    expect(relatives).to include("inner/lib.rb").and(satisfy { |paths| paths.none? { _1.include?("build/") } })
  end

  it "walks a directory outside any repository whole" do
    write("a.txt")
    write("sub/b.txt")

    expect(relatives).to eq(%w[a.txt sub/b.txt])
  end

  it "skips a .git directory it descends by hand" do
    write("a.txt")
    write("sub/.git/config")

    expect(relatives).to eq(["a.txt"])
  end

  it "skips a .git file, as a submodule or worktree pointer, it meets by hand" do
    write("a.txt")
    write("sub/.git", "gitdir: /elsewhere\n")

    expect(relatives).to eq(["a.txt"])
  end

  it "lists a repository holding a name that is not valid UTF-8" do
    init_repo
    write("ok.txt")
    File.binwrite(File.join(root.b, "bad\xE9.txt".b), "x\n")

    expect(walk.map { File.basename(_1).b }).to contain_exactly("ok.txt".b, "bad\xE9.txt".b)
  end

  it "yields absolute paths" do
    write("a.txt")

    expect(walk.to_a).to eq([File.join(root, "a.txt")])
  end

  it "lists a repository's files relative to a subdirectory it starts in" do
    init_repo
    write("pkg/one.rb")
    write("top.rb")

    expect(described_class.new(root: File.join(root, "pkg")).map { File.basename(_1) }).to eq(["one.rb"])
  end

  it "does not yield a tracked file deleted from the working tree" do
    init_repo
    write("gone.rb")
    write("kept.rb")
    git("add", ".")
    File.delete(File.join(root, "gone.rb"))

    expect(relatives).to eq(["kept.rb"])
  end

  it "reads only as many directories as the entries taken need" do
    40.times { |i| write(format("d%02d/f.txt", i)) }
    opened = 0
    allow(Dir).to receive(:each_child).and_wrap_original do |original, *args, &block|
      opened += 1
      original.call(*args, &block)
    end

    walk.first(5)

    expect(opened).to be < 40
  end

  it "walks by hand when git has no answer for a repository whose tree is all ignored" do
    init_repo
    write(".gitignore", "*\n")
    write("a.txt")

    expect(relatives).to eq(%w[.gitignore a.txt])
  end

  it "lets an error raised by the consumer's block propagate" do
    write("a.txt")

    expect { walk.each(&failing_consumer) }.to raise_error(Errno::EPIPE)
  end

  it "lets a consumer's error propagate from a git listing too" do
    init_repo
    write("a.txt")

    expect { walk.each(&failing_consumer) }.to raise_error(Errno::EPIPE)
  end

  describe "symbolic links" do
    before do
      write("real.txt")
      File.symlink("real.txt", File.join(root, "alias.txt"))
      File.symlink(".", File.join(root, "loop"))
    end

    it "leaves links out by default, and does not follow a directory link back into the tree" do
      expect(relatives).to eq(["real.txt"])
    end

    it "yields links when asked, still without descending a directory link" do
      linked = described_class.new(root:, links: true).map { _1.delete_prefix("#{root}/") }

      expect(linked).to eq(%w[alias.txt loop real.txt])
    end

    it "leaves a link out of a git listing by default" do
      init_repo

      expect(relatives).to eq(["real.txt"])
    end
  end

  it "drops a submodule gitlink, which git lists but is a directory" do
    init_repo
    write("kept.rb")
    FileUtils.mkdir_p(File.join(root, "sub"))
    git("update-index", "--add", "--cacheinfo", "160000,#{"a" * 40},sub")

    expect(relatives).to eq(["kept.rb"])
  end

  it "orders a git listing as the hand walk does, tracked and untracked alike" do
    init_repo
    write("z.rb")
    git("add", "z.rb")
    %w[b.rb a/z.rb a.rb].each { write(_1) }

    expect(relatives).to eq(%w[a/z.rb a.rb b.rb z.rb])
  end

  it "orders the hand walk the same way" do
    %w[z.rb b.rb a/z.rb a.rb].each { write(_1) }

    expect(relatives).to eq(%w[a/z.rb a.rb b.rb z.rb])
  end

  describe "#relative_tree" do
    it "tags files and directories as UTF-8 under a root spelled as BINARY bytes" do
      write("sub/one.rb")

      files, directories = described_class.new(root: root.b).relative_tree

      expect([*files, *directories].map(&:encoding).uniq).to eq([Encoding::UTF_8])
      expect(files + directories).to contain_exactly("sub/one.rb", "sub")
    end

    it "returns the listed files and the directories holding them, relative to the root" do
      write("src/sub/a.rb")
      write("top.rb")
      FileUtils.mkdir_p(File.join(root, "empty"))

      files, directories = walk.relative_tree

      expect(files).to contain_exactly("src/sub/a.rb", "top.rb")
      expect(directories).to contain_exactly("src", "src/sub")
    end

    it "tags every path as UTF-8 text, a name that is not valid text included" do
      File.binwrite(File.join(root, "bad\xFF.rb".b), "")

      files, = described_class.new(root: root.b).relative_tree

      expect(files.map(&:encoding)).to eq([Encoding::UTF_8])
      expect(files.first.b).to eq("bad\xFF.rb".b)
    end
  end
end
