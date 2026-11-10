# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../../../tools/test_map/map"
require_relative "../../../tools/test_map/map_store"

RSpec.describe TestMap::MapStore do
  let(:identity) do
    { "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@t", "GIT_COMMITTER_NAME" => "t",
      "GIT_COMMITTER_EMAIL" => "t@t" }
  end

  def git(dir, *args)
    out, err, st = Open3.capture3(identity.merge(SeedRepo::SCRUB), "git", "-C", dir, *args)
    raise err unless st.success?

    out.strip
  end

  def commit(dir, text)
    File.write(File.join(dir, "f.txt"), text)
    git(dir, "add", "f.txt")
    git(dir, "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", text)
    git(dir, "rev-parse", "HEAD^{tree}")
  end

  def map_for(tree) = TestMap::Map.new(tree:, boot: {}, specs: {})

  def stored(dir) = Dir.children(File.join(dir, ".git", "lain", "test-map")).sort

  def age(dir, tree, seconds_ago)
    time = Time.now - seconds_ago
    File.utime(time, time, File.join(dir, ".git", "lain", "test-map", "#{tree}.json"))
  end

  around do |example|
    Dir.mktmpdir do |root|
      @main = File.join(root, "main")
      @linked = File.join(root, "linked")
      Dir.mkdir(@main)
      git(@main, "init", "-q")
      @tree_one = commit(@main, "one")
      @first = git(@main, "rev-parse", "HEAD")
      @tree_two = commit(@main, "two")
      git(@main, "worktree", "add", "-q", "--detach", @linked, @first)
      example.run
    end
  end

  it "finds a map saved in the main checkout from a linked worktree" do
    described_class.new(repo: @main).save(map_for(@tree_two))

    expect(described_class.new(repo: @linked).for_tree(@tree_two).tree).to eq(@tree_two)
  end

  it "answers nil for an unknown tree and for a corrupt file" do
    store = described_class.new(repo: @main)
    store.save(map_for(@tree_two))
    File.write(File.join(@main, ".git", "lain", "test-map", "#{@tree_two}.json"), "{not json")

    expect([store.for_tree(@tree_one), store.for_tree(@tree_two)]).to eq([nil, nil])
  end

  it "leaves no temp file behind and overwrites a map for the same tree" do
    store = described_class.new(repo: @main)
    2.times { store.save(map_for(@tree_two)) }

    expect(stored(@main)).to eq(["#{@tree_two}.json"])
  end

  describe "pruning" do
    let(:fillers) { Array.new(6) { |i| (i + 1).to_s.rjust(40, "0") } }
    let(:ninth) { "f" * 40 }

    def seed_eight(store)
      store.save(map_for(@tree_one))
      age(@main, @tree_one, 1000)
      fillers.each_with_index do |tree, i|
        store.save(map_for(tree))
        age(@main, tree, 900 - i)
      end
      store.save(map_for(@tree_two))
      age(@main, @tree_two, 10)
    end

    it "keeps the newest 8 and every worktree's anchor" do
      store = described_class.new(repo: @main)
      seed_eight(store)
      store.save(map_for(ninth))

      expect(stored(@main)).to eq(([@tree_one, @tree_two, ninth] + fillers.drop(1)).map { |t| "#{t}.json" }.sort)
    end

    it "skips the whole prune when git cannot list the worktrees" do
      store = described_class.new(repo: @main)
      seed_eight(store)
      allow(TestMap::Git).to receive(:run).and_wrap_original do |original, *args, **opts|
        raise "git worktree failed" if args.first == "worktree"

        original.call(*args, **opts)
      end
      store.save(map_for(ninth))

      expect(stored(@main).size).to eq(9)
    end

    it "skips the whole prune when git cannot read an anchor's history" do
      store = described_class.new(repo: @main)
      seed_eight(store)
      allow(TestMap::Git).to receive(:run).and_wrap_original do |original, *args, **opts|
        raise "git log failed" if args.first == "log"

        original.call(*args, **opts)
      end
      store.save(map_for(ninth))

      expect(stored(@main).size).to eq(9)
    end

    it "still prunes when one file vanishes between listing and reading its mtime" do
      store = described_class.new(repo: @main)
      seed_eight(store)
      gone = File.join(@main, ".git", "lain", "test-map", "#{fillers.last}.json")
      allow(File).to receive(:mtime).and_wrap_original do |original, path, *rest|
        raise Errno::ENOENT, path if File.basename(path) == File.basename(gone)

        original.call(path, *rest)
      end
      extra = "e" * 40
      store.save(map_for(extra))
      age(@main, extra, 5)
      store.save(map_for(ninth))

      expect(stored(@main)).not_to include("#{fillers.first}.json")
    end

    it "sweeps temp files older than an hour and leaves recent ones" do
      store = described_class.new(repo: @main)
      store.save(map_for(@tree_two))
      map_dir = File.join(@main, ".git", "lain", "test-map")
      old = File.join(map_dir, ".stale.1.aaaa.tmp")
      recent = File.join(map_dir, ".fresh.2.bbbb.tmp")
      [old, recent].each { |f| File.write(f, "x") }
      File.utime(Time.now - 7200, Time.now - 7200, old)
      store.save(map_for(@tree_two))

      expect(Dir.children(map_dir).sort).to eq([File.basename(recent), "#{@tree_two}.json"].sort)
    end

    it "tolerates a file vanishing while it prunes" do
      store = described_class.new(repo: @main)
      seed_eight(store)
      allow(File).to receive(:delete).and_raise(Errno::ENOENT)

      expect { store.save(map_for(ninth)) }.not_to raise_error
    end
  end
end
