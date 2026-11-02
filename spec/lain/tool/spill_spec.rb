# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Tool::Spill do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmp = dir
      example.run
    end
  end

  let(:dir) { File.join(@tmp, "answers", "abc123") }

  it "writes the full answer first and the summary beside it, creating the dir" do
    paths = described_class.new(dir:).call(answer: "the whole answer", summary: "the short one")

    expect(paths.map { File.dirname(_1) }).to eq([dir, dir])
    expect(paths.map { File.read(_1) }).to eq(["the whole answer", "the short one"])
  end

  it "writes the answer alone when there is no summary" do
    paths = described_class.new(dir:).call(answer: "the whole answer")

    expect(paths.map { File.read(_1) }).to eq(["the whole answer"])
  end

  it "names each spill apart, so two answers never share a file" do
    spill = described_class.new(dir:)

    expect(spill.call(answer: "one")).not_to eq(spill.call(answer: "two"))
  end

  it "raises Unwritable, naming why, when the dir cannot be created" do
    blocker = File.join(@tmp, "a-file").tap { File.write(_1, "") }

    expect { described_class.new(dir: File.join(blocker, "answers")).call(answer: "x") }
      .to raise_error(described_class::Unwritable, /a-file/)
  end

  it "keeps its files to the owner: 0600 files in a 0700 dir" do
    paths = described_class.new(dir:).call(answer: "a", summary: "s")

    expect(paths.map { File.stat(_1).mode & 0o777 }).to eq([0o600, 0o600])
    expect(File.stat(dir).mode & 0o777).to eq(0o700)
  end

  it "never writes over a file already at the name it chose" do
    allow(SecureRandom).to receive(:hex).and_return("samehex0")
    allow(Time).to receive(:now).and_return(Time.utc(2026, 10, 31, 12))
    spill = described_class.new(dir:)
    first = spill.call(answer: "first").first

    expect { spill.call(answer: "second") }.to raise_error(described_class::Unwritable)
    expect(File.read(first)).to eq("first")
  end

  it "still hands back the answer's path when the summary cannot be written" do
    allow(File).to receive(:open).and_call_original
    allow(File).to receive(:open).with(/\.summary\.md\z/, any_args).and_raise(Errno::ENOSPC)

    paths = described_class.new(dir:).call(answer: "the whole answer", summary: "the short one")

    expect(paths.map { File.read(_1) }).to eq(["the whole answer"])
  end

  it "leaves no partial summary behind when its write fails after the file was made" do
    allow(File).to receive(:open).and_call_original
    allow(File).to receive(:open).with(/\.summary\.md\z/, any_args) do |path, *|
      File.new(path, "w").close
      raise Errno::ENOSPC
    end

    described_class.new(dir:).call(answer: "the whole answer", summary: "the short one")

    expect(Dir.children(dir).grep(/\.summary\.md\z/)).to be_empty
  end

  describe "#keep, which answers through the outcome it reached" do
    let(:outcomes) do
      described_class::Outcomes.new(kept: ->(paths) { [:kept, paths.size] }, unwritable: ->(why) { [:unwritable, why] },
                                    unkept: -> { [:unkept] })
    end

    it "answers kept with the paths it wrote" do
      expect(described_class.new(dir:).keep("a", "s", outcomes)).to eq([:kept, 2])
    end

    it "answers unwritable, naming why, when the dir cannot be made" do
      blocker = File.join(@tmp, "a-file").tap { File.write(_1, "") }

      expect(described_class.new(dir: File.join(blocker, "x")).keep("a", nil, outcomes))
        .to match([:unwritable, /a-file/])
    end

    it "answers unkept through its Null, raising nothing" do
      expect(described_class::Null.keep("a", nil, outcomes)).to eq([:unkept])
    end
  end

  it "keys the home by project under the state home's answers dir" do
    paths = Lain::Paths.new
    homes = [File.join(@tmp, "one"), File.join(@tmp, "two")].map { described_class.home(paths, _1) }

    expect(homes.map { File.dirname(_1) }.uniq).to eq([File.join(paths.state_home, "answers")])
    expect(homes.uniq.size).to eq(2)
  end

  # Under the default state home; a compact stamp such as 20261102T084512
  # beside the random suffix read as a high-entropy token there.
  it "names a file so its path under the default state home does not read as a credential" do
    paths = Array.new(50) { "/home/user/.local/state/lain/answers/3fa9c01b7e2d/#{described_class.stem}.txt" }

    expect(paths.map { Lain::Sensitivity::Regions.detect("the full output is at #{_1}; read it") }).to all(be_empty)
  end

  describe "#pending, a result written while it is produced" do
    let(:spill) { described_class.new(dir:) }

    it "holds a result that stays under the threshold in memory, opening no file" do
      pending = spill.pending(threshold: 8)
      pending << "abc" << "def"

      expect(pending).to have_attributes(spilled?: false, size: 6, head: "abcdef")
      expect(Dir.exist?(dir) ? Dir.children(dir) : []).to be_empty
    end

    it "writes every byte to a 0600 pending file once it passes the threshold, keeping the head" do
      pending = spill.pending(threshold: 4)
      pending << "abc" << "defgh"

      expect(pending).to have_attributes(spilled?: true, size: 8, kept: 8, head: "abcd")
      expect(pending.path).to end_with(".pending")
      expect(File.binread(pending.path)).to eq("abcdefgh")
      expect(File.stat(pending.path).mode & 0o777).to eq(0o600)
    end

    it "keeps no more than its cap in the file while counting every byte" do
      pending = spill.pending(threshold: 2, cap: 5)
      pending << ("x" * 9)

      expect(pending).to have_attributes(size: 9, kept: 5)
      expect(File.size(pending.path)).to eq(5)
    end

    it "commits by renaming the pending file to its kept name" do
      pending = spill.pending(threshold: 1)
      pending << "abc"
      was = pending.path

      kept = pending.commit

      expect(File.exist?(was)).to be(false)
      expect(kept).to end_with(".txt")
      expect(File.binread(kept)).to eq("abc")
    end

    it "discards by deleting the pending file" do
      pending = spill.pending(threshold: 1)
      pending << "abc"
      was = pending.path

      pending.discard

      expect(File.exist?(was)).to be(false)
      expect(Dir.children(dir)).to be_empty
    end

    it "is left unspilled, raising nothing, when the dir cannot be made" do
      blocker = File.join(@tmp, "a-file").tap { File.write(_1, "") }
      pending = described_class.new(dir: File.join(blocker, "x")).pending(threshold: 1)

      expect { pending << "abc" }.not_to raise_error
      expect(pending).to have_attributes(spilled?: false, size: 3)
    end

    # A sweep from a second session can take the lock in the moment between
    # the open and the flock, and delete the name; the bytes are still the
    # descriptor's, so they are read and kept from there.
    it "keeps every byte from its descriptor after its name was deleted" do
      pending = spill.pending(threshold: 2)
      pending << "abc"
      File.unlink(pending.path)
      pending << "def"

      expect(pending.whole).to eq("abcdef")
      expect(File.binread(pending.commit)).to eq("abcdef")
    end

    it "keeps its own bytes, not those of a file swapped in under its name" do
      pending = spill.pending(threshold: 2)
      pending << "abcdef"
      File.unlink(pending.path)
      File.write(pending.path, "clean\n")

      expect(pending.whole).to eq("abcdef")
      expect(File.binread(pending.commit)).to eq("abcdef")
    end

    it "deletes on discard only the file it opened, leaving one swapped in under its name" do
      pending = spill.pending(threshold: 2)
      pending << "abcdef"
      swapped = pending.path
      File.unlink(swapped)
      File.write(swapped, "theirs")

      pending.discard

      expect(File.read(swapped)).to eq("theirs")
    end

    it "neither writes over nor deletes a file already at the name it chose" do
      allow(SecureRandom).to receive(:hex).and_return("samehex0")
      allow(Time).to receive(:now).and_return(Time.utc(2026, 10, 31, 12))
      FileUtils.mkdir_p(dir)
      theirs = File.join(dir, "#{described_class.stem}.pending").tap { File.write(_1, "theirs") }
      pending = spill.pending(threshold: 2)

      pending << "abcdef"

      expect(pending.spilled?).to be(false)
      expect(File.read(theirs)).to eq("theirs")
    end

    it "keeps nothing through its Null" do
      pending = described_class::Null.pending(threshold: 2)
      pending << "abcdef"

      expect(pending).to have_attributes(spilled?: false, size: 6, head: "ab")
    end
  end

  describe "#sweep, run when a session starts" do
    let(:spill) { described_class.new(dir:) }

    def file(name, age: 0)
      FileUtils.mkdir_p(dir)
      File.join(dir, name).tap do |path|
        File.write(path, "kept")
        File.utime(Time.now - age, Time.now - age, path)
      end
    end

    it "removes a spill 8 days old and a leftover pending file" do
      old = file("old.txt", age: 8 * 24 * 60 * 60)
      leftover = file("left.pending")

      spill.sweep

      expect([old, leftover].map { File.exist?(_1) }).to eq([false, false])
    end

    it "keeps a spill younger than 7 days" do
      young = file("young.md", age: 6 * 24 * 60 * 60)

      spill.sweep

      expect(File.exist?(young)).to be(true)
    end

    it "keeps a pending file another open handle holds locked" do
      live = file("live.pending")

      File.open(live) do |held|
        held.flock(File::LOCK_EX)
        spill.sweep
      end

      expect(File.exist?(live)).to be(true)
    end

    it "keeps the file a live pending write holds open" do
      pending = spill.pending(threshold: 1)
      pending << "abc"

      spill.sweep

      expect(File.binread(pending.path)).to eq("abc")
    end

    it "sweeps nothing when the dir was never made" do
      expect(spill.sweep).to eq([])
    end
  end
end
