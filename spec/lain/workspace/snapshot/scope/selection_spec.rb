# frozen_string_literal: true

require "tmpdir"

# The containment test every scope's answer passes through, so a path outside
# the snapshot's root is dropped rather than keyed by a ../ form no undo could
# act on. It is a LEXICAL test, deliberately -- the matrix below is what
# "lexical" means in practice, including the one case where it disagrees with
# the plan-scope gate.
RSpec.describe Lain::Workspace::Snapshot::Scope::Selection do
  def split(paths, root) = described_class.within(paths, root)

  describe ".within, over every root shape" do
    it "keeps what is under the root and refuses the rest" do
      selection = split(%w[/w/a /w/deep/b /elsewhere/c], "/w")

      expect([selection.kept, selection.outside]).to eq([%w[/w/a /w/deep/b], %w[/elsewhere/c]])
    end

    # The separator is the test, not the prefix: /w-2 merely begins with /w.
    it "refuses a sibling whose name begins with the root's" do
      expect(split(%w[/w-2/a], "/w").outside).to eq(%w[/w-2/a])
    end

    it "keeps the root itself, which is a path inside it" do
      expect(split(%w[/w], "/w").kept).to eq(%w[/w])
    end

    it "reads a trailing slash on the root as no slash at all" do
      selection = split(%w[/w/a /w-2/a], "/w/")

      expect([selection.kept, selection.outside]).to eq([%w[/w/a], %w[/w-2/a]])
    end

    it "keeps a path spelled with a trailing slash" do
      expect(split(["/w/a/"], "/w").kept).to eq(["/w/a/"])
    end

    # `..` resolves BEFORE the test, so where a path lands decides, not how it
    # is spelled -- the same identity {Snapshot#relative} keys by.
    it "judges a path by where its .. lands, not by its spelling" do
      selection = split(["/w/sub/../a.rb", "/w/../a.rb"], "/w")

      expect([selection.kept, selection.outside]).to eq([["/w/sub/../a.rb"], ["/w/../a.rb"]])
    end

    it "resolves a relative path against the process cwd, as expand_path does" do
      expect([split(%w[rel.txt], Dir.pwd).kept, split(%w[rel.txt], "/w").outside])
        .to eq([%w[rel.txt], %w[rel.txt]])
    end

    it "keeps everything under a root of /, the degenerate case" do
      expect(split(%w[/etc/x], "/").outside).to eq([])
    end

    it "answers an empty write set with two empty halves" do
      expect([split([], "/w").kept, split([], "/w").outside]).to eq([[], []])
    end

    it "takes a Pathname root, which is what a Snapshot hands it" do
      expect(split(%w[/w/a], Pathname.new("/w")).kept).to eq(%w[/w/a])
    end

    it "reports one path once, however many times it was recorded" do
      expect(split(%w[/w/a /w/a /x /x], "/w").then { |split| [split.kept, split.outside] })
        .to eq([%w[/w/a], %w[/x]])
    end
  end

  # The divergence, pinned rather than fixed: {Lain::Session::Confined#holds?}
  # -- what the plan-scope gate admits a write by -- resolves realpaths, so it
  # and this test can disagree about one path. See the class's own note.
  describe "a symlinked root, where the gate and this test disagree" do
    around do |example|
      Dir.mktmpdir("lain-selection") do |base|
        @real = File.realpath(File.join(base, "real").tap { |path| Dir.mkdir(path) })
        @link = File.join(base, "link")
        File.symlink(@real, @link)
        example.run
      end
    end

    attr_reader :real, :link

    it "refuses a write under the root's real path when the root is spelled as the link" do
      expect(split([File.join(real, "a.txt")], link).outside).to eq([File.join(real, "a.txt")])
    end

    it "refuses a write spelled through the link when the root is its real path" do
      expect(split([File.join(link, "a.txt")], real).outside).to eq([File.join(link, "a.txt")])
    end
  end

  describe "as a value" do
    it "is deeply frozen however it was built, so it stays Ractor-shareable" do
      built = described_class.new(kept: ["/w/a"], outside: ["/x"])

      expect(built).to be_deeply_frozen
      expect(Ractor.shareable?(built)).to be(true)
      expect(Ractor.shareable?(split(%w[/w/a /x], "/w"))).to be(true)
    end

    it "freezes the paths themselves, not only the arrays holding them" do
      built = described_class.new(kept: [+"/w/a"], outside: [+"/x"])

      expect([built.kept.first, built.outside.first]).to all(be_frozen)
    end

    it "is equal to another split of the same halves" do
      expect(split(%w[/w/a /x], "/w")).to eq(described_class.new(kept: %w[/w/a], outside: %w[/x]))
    end
  end

  # Enumerable over the KEPT half, because that is what a snapshot captures:
  # Snapshot#manifest sorts it exactly as it sorted the Array it replaced.
  describe "as an Enumerable over what is captured" do
    subject(:selection) { split(%w[/w/b /w/a /elsewhere/c], "/w") }

    it "enumerates the kept paths and nothing else" do
      expect(selection.to_a).to eq(%w[/w/b /w/a])
    end

    it "sorts, as the manifest does" do
      expect(selection.sort).to eq(%w[/w/a /w/b])
    end

    it "maps without the caller reaching for the kept array" do
      expect(selection.map { |path| File.basename(path) }).to eq(%w[b a])
    end

    it "answers each with no block with an Enumerator" do
      expect(selection.each).to be_a(Enumerator)
    end
  end
end
