# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Frontend::Completion::Sources do
  # A command is anything answering #name -- what Lain::CLI::Command::Registry
  # yields. The source depends on that message, never on the type.
  def command(name) = double(name:)

  describe "#sigil?" do
    it "recognizes the two sigils that name a completion source" do
      sources = described_class.new

      expect(sources.sigil?("/")).to be(true)
      expect(sources.sigil?("@")).to be(true)
    end

    it "recognizes nothing else" do
      expect(described_class.new.sigil?("#")).to be(false)
    end
  end

  describe "#for" do
    it "offers a registered command for a slash prefix" do
      sources = described_class.new(commands: [command("help"), command("status")])

      matched = sources.for(described_class::COMMAND).match("st").map { |match| match["candidate"] }

      expect(matched).to include("status")
    end

    it "offers a skill alongside the commands" do
      sources = described_class.new(commands: [command("help")], skills: %i[summarize])

      candidates = sources.for(described_class::COMMAND).candidates

      expect(candidates).to include("help").and include("summarize")
    end

    it "offers a project path for an at prefix" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "lain", "frontend"))
        File.write(File.join(dir, "lib", "lain", "frontend", "tty.rb"), "")

        matched = described_class.new(root: dir).for(described_class::PATH).match("ttyrb")

        expect(matched.map { |match| match["candidate"] }).to eq(["lib/lain/frontend/tty.rb"])
      end
    end

    it "leaves a repo's dot directories out of the candidate set" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".git"))
        File.write(File.join(dir, ".git", "HEAD"), "ref: refs/heads/main\n")
        File.write(File.join(dir, "README.md"), "")

        expect(described_class.new(root: dir).for(described_class::PATH).candidates).to eq(["README.md"])
      end
    end

    it "offers files, never the directories on the way to them" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "a.rb"), "")

        expect(described_class.new(root: dir).for(described_class::PATH).candidates).to eq(["lib/a.rb"])
      end
    end

    it "walks the directory once however many times completion is requested" do
      Dir.mktmpdir do |dir|
        1000.times { |i| File.write(File.join(dir, "file#{i}.txt"), "") }
        sources = described_class.new(root: dir)
        sources.for(described_class::PATH)
        allow(Find).to receive(:find).and_call_original

        3.times { sources.for(described_class::PATH) }

        expect(Find).not_to have_received(:find)
      end
    end

    it "never descends into a pruned build directory" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "target", "debug"))
        File.write(File.join(dir, "target", "debug", "junk"), "")
        File.write(File.join(dir, "keep.rb"), "")

        expect(described_class.new(root: dir).for(described_class::PATH).candidates).to eq(["keep.rb"])
      end
    end

    # A filename is attacker-controlled in any cloned repo -- the same value
    # class as the git branch name Ext::Prompt#sanitize exists for.
    it "strips control bytes out of a filename so a hostile name cannot drive the terminal" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "ev\e[2Jil.rb"), "")

        expect(described_class.new(root: dir).for(described_class::PATH).candidates).to eq(["ev[2Jil.rb"])
      end
    end

    it "strips a newline out of a filename, which would otherwise break the menu's row accounting" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "two\nlines.rb"), "")

        expect(described_class.new(root: dir).for(described_class::PATH).candidates).to eq(["twolines.rb"])
      end
    end

    # Scrubbing to "" is not a candidate, it is a ghost row: it sorts first and
    # draws a bare sigil the human cannot act on.
    it "drops a filename that is nothing but control bytes, rather than offering an empty row" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "\x01\x02"), "")
        File.write(File.join(dir, "alpha.rb"), "")

        expect(described_class.new(root: dir).for(described_class::PATH).candidates).to eq(["alpha.rb"])
      end
    end

    it "drops a command whose whole name is control bytes" do
      sources = described_class.new(commands: [command("\x01"), command("status")])

      expect(sources.for(described_class::COMMAND).candidates).to eq(["status"])
    end

    it "strips control bytes out of a command name too" do
      sources = described_class.new(commands: [command("st\e[2Jatus")])

      expect(sources.for(described_class::COMMAND).candidates).to eq(["st[2Jatus"])
    end

    it "hands back the same matcher rather than rebuilding it" do
      sources = described_class.new(commands: [command("help")])

      expect(sources.for(described_class::COMMAND)).to be(sources.for(described_class::COMMAND))
    end

    it "raises rather than guessing at a sigil that names no source" do
      expect { described_class.new.for("#") }.to raise_error(ArgumentError, /names no completion source/)
    end
  end
end
