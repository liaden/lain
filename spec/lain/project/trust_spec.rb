# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "timeout"

RSpec.describe Lain::Project::Trust do
  around do |example|
    Dir.mktmpdir("lain-trust") do |tmp|
      @tmp = tmp
      example.run
    end
  end

  # Its own state home per example: the suite's is shared by every example in
  # the process, and a mark another example granted would make bytes trusted here.
  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@tmp, "state"), "HOME" => @tmp }) }

  def project(name = "project", files = {})
    root = File.join(@tmp, name)
    FileUtils.mkdir_p(File.join(root, ".lain"))
    files.each { |file, body| File.write(File.join(root, ".lain", file), body) }
    root
  end

  def trust_for(root) = described_class.for(project_dir: Lain::ProjectDir.new(root:, paths:), paths:)

  describe "a project with no .lain/*.rb" do
    it "needs no trust and records nothing" do
      trust = trust_for(project("bare", "config.toml" => "[shell]\n"))

      expect(trust).to be_trusted
      expect { trust.require! }.not_to raise_error
      expect(Dir.exist?(File.join(@tmp, "state"))).to be(false)
    end
  end

  describe "an untrusted project" do
    it "refuses, naming each Ruby file and `lain trust`" do
      root = project("app", "summarizers.rb" => "summarizer 'x' do\nend\n", "services.rb" => "postgres\n")

      expect { trust_for(root).require! }.to raise_error(described_class::Untrusted) { |error|
        expect(error).to be_a(Lain::Error)
        expect(error.message).to include(File.join(root, ".lain", "summarizers.rb"))
          .and include(File.join(root, ".lain", "services.rb"))
          .and include("lain trust")
      }
    end
  end

  describe "#grant!" do
    it "records a mark keyed on the digest, after which the project is trusted" do
      root = project("app", "summarizers.rb" => "one\n")
      trust_for(root).grant!

      expect(trust_for(root)).to be_trusted
      expect(File.read(File.join(@tmp, "state", "lain", "trust", trust_for(root).digest)))
        .to eq("#{trust_for(root).digest}\n")
    end

    it "is a new decision when a file changes by one byte" do
      root = project("app", "summarizers.rb" => "one\n")
      trust_for(root).grant!
      File.write(File.join(root, ".lain", "summarizers.rb"), "one!\n")

      expect { trust_for(root).require! }.to raise_error(described_class::Untrusted)
    end

    it "is a new decision when a Ruby file is added beside the trusted ones" do
      root = project("app", "summarizers.rb" => "one\n")
      trust_for(root).grant!
      File.write(File.join(root, ".lain", "config.rb"), "shell exclude: []\n")

      expect(trust_for(root)).not_to be_trusted
    end

    it "is a new decision when the same bytes move to another file name" do
      trust_for(project("app", "summarizers.rb" => "postgres\n")).grant!

      expect(trust_for(project("moved", "services.rb" => "postgres\n"))).not_to be_trusted
    end

    it "carries to another root holding byte-identical files, like a worker checkout" do
      trust_for(project("app", "summarizers.rb" => "one\n", "services.rb" => "postgres\n")).grant!

      expect(trust_for(project("checkout", "services.rb" => "postgres\n", "summarizers.rb" => "one\n")))
        .to be_trusted
    end
  end

  describe "what the digest covers" do
    it "ignores files that are not .lain/*.rb" do
      root = project("app", "summarizers.rb" => "one\n")
      trust_for(root).grant!
      FileUtils.mkdir_p(File.join(root, ".lain", "summarizers"))
      File.write(File.join(root, ".lain", "summarizers", "draft.rb"), "anything\n")
      File.write(File.join(root, ".lain", "config.toml"), "[shell]\n")

      expect(trust_for(root)).to be_trusted
    end

    it "holds the bytes it digested, keyed by each file's full path" do
      root = project("app", "summarizers.rb" => "one\n")

      expect(trust_for(root).sources).to eq(File.join(root, ".lain", "summarizers.rb") => "one\n")
    end
  end

  describe "the digest's framing" do
    # Without a length prefix both spell "a.rbb.rbxy", and one would trust the other.
    it "tells a body that ends in a name from a second file" do
      one = trust_for(project("one", "a.rb" => "b.rbxy")).digest
      two = trust_for(project("two", "a.rb" => "", "b.rb" => "xy")).digest

      expect(one).not_to eq(two)
    end
  end

  describe "an entry that is not a regular file" do
    # Reading a FIFO with no writer blocks forever, so one planted in `.lain/`
    # would hang every launch.
    it "skips a FIFO named *.rb rather than reading it" do
      root = project("app", "summarizers.rb" => "one\n")
      File.mkfifo(File.join(root, ".lain", "x.rb"))

      sources = Timeout.timeout(5) { trust_for(root).sources }

      expect(sources.keys).to eq([File.join(root, ".lain", "summarizers.rb")])
    end
  end

  describe "a file name that could drive the terminal" do
    it "reaches the refusal with its control and format characters escaped" do
      root = project("app", "\e[2J\e[Hevil\u202E.rb" => "one\n")

      expect { trust_for(root).require! }.to raise_error(described_class::Untrusted) { |error|
        expect(error.message).not_to match(/[\e\u202E]/)
        expect(error.message).to include("\\e[2J\\e[Hevil\\u202E.rb")
      }
    end
  end

  describe "what cannot be read" do
    # A Lain::Error, so the launch renders it; its own class, because no
    # trust decision was made and `lain trust` would not help.
    it "is a Lain::Error distinct from Untrusted" do
      expect(described_class::Unreadable.ancestors).to include(Lain::Error)
      expect(described_class::Unreadable.ancestors).not_to include(described_class::Untrusted)
    end

    it "refuses as Unreadable, not Untrusted, naming a .lain/*.rb it cannot read" do
      root = project("app", "summarizers.rb" => "one\n", "other.rb" => "two\n")
      File.chmod(0o000, File.join(root, ".lain", "other.rb"))

      expect { trust_for(root) }
        .to raise_error(described_class::Unreadable, /#{Regexp.escape(File.join(root, ".lain", "other.rb"))}/)
    end

    it "refuses as Unreadable, not Untrusted, naming a mark it cannot read" do
      root = project("app", "summarizers.rb" => "one\n")
      mark = trust_for(root).grant!
      File.chmod(0o000, mark)

      expect { trust_for(root).trusted? }.to raise_error(described_class::Unreadable, /#{Regexp.escape(mark)}/)
    end
  end

  describe "a mark that is not a regular file holding its digest" do
    it "grants nothing when a directory sits where the mark would" do
      root = project("app", "summarizers.rb" => "one\n")
      FileUtils.mkdir_p(File.join(@tmp, "state", "lain", "trust", trust_for(root).digest))

      expect(trust_for(root)).not_to be_trusted
    end

    it "grants nothing when the mark holds anything but its digest" do
      root = project("app", "summarizers.rb" => "one\n")
      mark = File.join(@tmp, "state", "lain", "trust", trust_for(root).digest)
      FileUtils.mkdir_p(File.dirname(mark))
      File.write(mark, "")

      expect(trust_for(root)).not_to be_trusted
    end
  end

  it "reads the state home off the ambient Paths when none is injected" do
    root = project("ambient", "summarizers.rb" => "ambient #{object_id}\n")
    described_class.for(project_dir: Lain::ProjectDir.new(root:)).grant!

    expect(described_class.for(project_dir: Lain::ProjectDir.new(root:))).to be_trusted
    expect(trust_for(root)).not_to be_trusted
  end
end
