# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Workspace::Revert do
  around do |example|
    Dir.mktmpdir("lain-revert") do |root|
      @root = root
      example.run
    end
  end

  attr_reader :root

  def side(bytes, mode = nil) = described_class::Side.new(bytes:, mode:)

  def move(key, before:, after:) = described_class::Move.new(key:, before:, after:)

  def put(key, bytes, mode: nil)
    File.join(root, key).tap do |path|
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, bytes)
      File.chmod(mode, path) if mode
    end
  end

  def read(key) = File.binread(File.join(root, key))

  def exist?(key) = File.exist?(File.join(root, key))

  def executable?(key) = File.stat(File.join(root, key)).mode.anybits?(0o111)

  def revert = described_class.new(root:)

  def reasons(moves) = revert.blockers(moves).to_h { |blocker| [blocker.key, blocker.reason] }

  describe "#apply" do
    it "puts back each path's earlier bytes and deletes what the turn created" do
      put("x.txt", "x v2")
      put("made.txt", "new")

      result = revert.apply([move("x.txt", before: side("x v1"), after: side("x v2")),
                             move("made.txt", before: nil, after: side("new"))])

      expect(read("x.txt")).to eq("x v1")
      expect(exist?("made.txt")).to be(false)
      expect(result.to_h).to eq(written: ["x.txt"], deleted: ["made.txt"])
    end

    it "brings back a file the turn deleted" do
      revert.apply([move("gone.txt", before: side("was here"), after: nil)])

      expect(read("gone.txt")).to eq("was here")
    end

    it "touches no path outside its moves, so a file made after the turn is left alone" do
      put("x.txt", "x v2")
      put("human.txt", "mine")

      revert.apply([move("x.txt", before: side("x v1"), after: side("x v2"))])

      expect(read("human.txt")).to eq("mine")
    end

    it "puts the executable bit back as the earlier mode had it, in both directions" do
      put("run.sh", "echo\n", mode: 0o755)
      put("tool.sh", "v1\n", mode: 0o644)

      revert.apply([move("run.sh", before: side("echo\n", "100644"), after: side("echo\n", "100755")),
                    move("tool.sh", before: side("v0\n", "100755"), after: side("v1\n", "100644"))])

      expect(executable?("run.sh")).to be(false)
      expect([read("tool.sh"), executable?("tool.sh")]).to eq(["v0\n", true])
    end

    # The turn replaced a directory with a file of the same name: its own file
    # is removed first, so the directory can come back.
    it "puts a directory back where the turn left a file" do
      put("d", "flat\n")

      revert.apply([move("d/f.txt", before: side("inner\n"), after: nil),
                    move("d", before: nil, after: side("flat\n"))])

      expect(read("d/f.txt")).to eq("inner\n")
    end

    # The turn replaced a file with a directory: the directory's files are the
    # turn's own, so once they are removed the emptied directory can go.
    it "puts a file back where the turn left a directory" do
      put("e/g", "g\n")

      revert.apply([move("e", before: side("i was a file\n"), after: nil),
                    move("e/g", before: nil, after: side("g\n"))])

      expect(read("e")).to eq("i was a file\n")
    end

    it "refuses before anything moves, naming the blocked path" do
      put("x.txt", "edited by hand")
      put("made.txt", "new")
      moves = [move("made.txt", before: nil, after: side("new")),
               move("x.txt", before: side("x v1"), after: side("x v2"))]

      expect { revert.apply(moves) }.to raise_error(described_class::Blocked) do |error|
        expect(error.blockers.map(&:key)).to eq(["x.txt"])
      end
      expect(exist?("made.txt")).to be(true)
    end
  end

  describe "#blockers" do
    it "names a path changed since the turn as dirty" do
      put("x.txt", "edited by hand")

      expect(reasons([move("x.txt", before: side("x v1"), after: side("x v2"))])).to eq("x.txt" => :dirty)
    end

    it "names a path the turn deleted that something has since put back as dirty" do
      put("gone.txt", "recreated")

      expect(reasons([move("gone.txt", before: side("was"), after: nil)])).to eq("gone.txt" => :dirty)
    end

    it "names a path that vanished since the turn as dirty, rather than resurrecting it" do
      expect(reasons([move("x.txt", before: side("x v1"), after: side("x v2"))])).to eq("x.txt" => :dirty)
    end

    it "names an executable bit flipped since the turn as dirty" do
      put("run.sh", "echo\n", mode: 0o644)

      expect(reasons([move("run.sh", before: side("echo\n", "100644"), after: side("echo\n", "100755"))]))
        .to eq("run.sh" => :dirty)
    end

    it "names a key outside the root" do
      expect(reasons([move("../out.txt", before: side("a"), after: side("b"))])).to eq("../out.txt" => :outside_root)
    end

    it "names a symlink at the path, and never follows it" do
      target = put("target.txt", "x v2")
      File.symlink(target, File.join(root, "link"))

      expect(reasons([move("link", before: side("x v1"), after: side("x v2"))])).to eq("link" => :symlink)
      expect(read("target.txt")).to eq("x v2")
    end

    it "names a side the record holds as a symlink, which a restore of bytes cannot put back" do
      File.symlink("/elsewhere", File.join(root, "link"))

      expect(reasons([move("link", before: nil, after: side("/elsewhere", "120000"))])).to eq("link" => :symlink)
    end

    it "names a side the record holds as a nested repository" do
      expect(reasons([move("vendor", before: side("abc", "160000"), after: nil)])).to eq("vendor" => :nested_repository)
    end

    it "names a directory the turn did not make standing where a file goes back" do
      put("e/mine.txt", "the human's")

      expect(reasons([move("e", before: side("i was a file\n"), after: nil)])).to eq("e" => :directory)
    end

    it "names a file the turn did not make standing where a directory goes back" do
      put("d", "the human's flat file")

      expect(reasons([move("d/f.txt", before: side("inner\n"), after: nil)])).to eq("d/f.txt" => :directory)
    end
  end
end
