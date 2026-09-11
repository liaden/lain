# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# One turn's before-tree and after-tree, and the moves that undo it.
RSpec.describe Lain::Workspace::Snapshot::Scope::ShadowGit::TreePair, :seam do
  around do |example|
    Dir.mktmpdir("lain-tree-pair-project") do |project|
      Dir.mktmpdir("lain-tree-pair-state") do |state|
        @project = File.realpath(project)
        @state = File.realpath(state)
        example.run
      end
    end
  end

  attr_reader :project

  let(:repository) do
    Lain::Workspace::Snapshot::Scope::ShadowGit::Repository.open(
      root: project, paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state })
    )
  end

  def put(name, bytes, mode: nil)
    File.join(project, name).tap do |path|
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, bytes)
      File.chmod(mode, path) if mode
    end
  end

  def pair_over
    before = repository.stage
    yield
    described_class.new(repository:, before:, after: repository.stage)
  end

  def side(bytes, mode) = Lain::Workspace::Revert::Side.new(bytes:, mode:)

  it "has not moved when the turn changed nothing" do
    put("a.txt", "a\n")

    expect(pair_over { :nothing_changes }).not_to be_moved
  end

  it "names the paths the turn changed, and only those" do
    put("keep.txt", "keep\n")
    pair = pair_over { put("made.txt", "m\n") }

    expect(pair).to be_moved
    expect(pair.keys).to eq(["made.txt"])
  end

  it "turns each row into a move carrying both sides' bytes and modes" do
    put("old.txt", "old\n")
    put("mod.txt", "m0\n")
    put("run.sh", "echo\n", mode: 0o644)
    pair = pair_over do
      File.delete(File.join(project, "old.txt"))
      put("new.txt", "n\n")
      put("mod.txt", "m1\n")
      File.chmod(0o755, File.join(project, "run.sh"))
    end

    expect(pair.moves.to_h { |move| [move.key, [move.before, move.after]] }).to eq(
      "old.txt" => [side("old\n", "100644"), nil],
      "new.txt" => [nil, side("n\n", "100644")],
      "mod.txt" => [side("m0\n", "100644"), side("m1\n", "100644")],
      "run.sh" => [side("echo\n", "100644"), side("echo\n", "100755")]
    )
  end

  it "carries binary bytes exactly" do
    bytes = (0..255).map(&:chr).join.b * 16
    put("blob.bin", bytes)

    move = pair_over { put("blob.bin", "X") }.moves.first

    expect(move.before.bytes).to eq(bytes)
  end

  it "asks the store whether a path is ignored" do
    put(".gitignore", "*.log\n")

    expect(pair_over { :nothing_changes }.ignored?("app.log")).to be(true)
  end
end
