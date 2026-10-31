# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Tools::Subagent::Spill do
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
end
