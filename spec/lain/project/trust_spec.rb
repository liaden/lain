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

    it "does not carry to another root holding byte-identical files" do
      trust_for(project("app", "summarizers.rb" => "one\n", "services.rb" => "postgres\n")).grant!

      other = trust_for(project("checkout", "services.rb" => "postgres\n", "summarizers.rb" => "one\n"))

      expect(other).not_to be_trusted
      expect { other.require! }.to raise_error(described_class::Untrusted, /lain trust .*checkout/)
    end

    it "carries to a linked worktree that inherits the trusted root's .lain" do
      root = project("app", "config.rb" => "one\n")
      lease = File.join(@tmp, "lease")
      admin = File.join(root, ".git", "worktrees", "wt")
      FileUtils.mkdir_p([admin, lease])
      File.write(File.join(admin, "commondir"), "../..\n")
      File.write(File.join(lease, ".git"), "gitdir: #{admin}\n")
      trust_for(root).grant!

      expect(trust_for(lease)).to be_trusted
    end

    it "re-asks once for a mark written under the content-only key" do
      root = project("app", "config.rb" => "x\n")
      old = Digest::SHA256.hexdigest("9:config.rb2:x\n")
      Lain::Project::Trust::Record.new(paths:).grant(old)

      expect(trust_for(root)).not_to be_trusted
      trust_for(root).grant!
      expect(trust_for(root)).to be_trusted
    end
  end

  describe "#content_digest" do
    it "is the old content-only stream, the same in any root" do
      one = trust_for(project("one", "config.rb" => "x\n"))
      two = trust_for(project("two", "config.rb" => "x\n"))

      expect(one.content_digest).to eq(Digest::SHA256.hexdigest("9:config.rb2:x\n"))
      expect(two.content_digest).to eq(one.content_digest)
      expect(two.digest).not_to eq(one.digest)
    end
  end

  describe "#require! vouched_by:" do
    it "accepts byte-identical files in another root when the voucher is trusted" do
      subject_trust = trust_for(project("subject", "config.rb" => "x\n"))
      subject_trust.grant!

      expect { trust_for(project("copy", "config.rb" => "x\n")).require!(vouched_by: subject_trust) }
        .not_to raise_error
    end

    it "refuses changed bytes even when the voucher is trusted" do
      subject_trust = trust_for(project("subject", "config.rb" => "x\n"))
      subject_trust.grant!

      expect { trust_for(project("copy", "config.rb" => "y\n")).require!(vouched_by: subject_trust) }
        .to raise_error(described_class::Untrusted)
    end

    it "refuses when the voucher itself is untrusted" do
      subject_trust = trust_for(project("subject", "config.rb" => "x\n"))

      expect { trust_for(project("copy", "config.rb" => "x\n")).require!(vouched_by: subject_trust) }
        .to raise_error(described_class::Untrusted)
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

  describe "the project digest's inputs" do
    # Every mark already granted on a machine is this digest; changing what
    # feeds it would void them all.
    it "is the resolved project root and each file's length-prefixed name and bytes, and nothing else" do
      root = project("app", "config.rb" => "x\n")
      digest = trust_for(root).digest

      expect(digest).to eq(Digest::SHA256.hexdigest("root:#{File.realpath(root)}9:config.rb2:x\n"))
    end
  end

  describe "a project reached through a link" do
    it "digests the same as the project reached directly" do
      root = project("app", "config.rb" => "x\n")
      link = File.join(@tmp, "app-link")
      File.symlink(root, link)

      expect(trust_for(link).digest).to eq(trust_for(root).digest)
    end

    it "digests a root that does not exist by its expanded spelling" do
      FileUtils.mkdir_p(File.join(@tmp, "ghost", ".lain"))
      File.write(File.join(@tmp, "ghost", ".lain", "config.rb"), "x\n")
      dir = Lain::ProjectDir.new(root: File.join(@tmp, "ghost"), paths:)
      FileUtils.rm_rf(File.join(@tmp, "ghost"))

      expect(described_class.for(project_dir: dir, paths:).digest)
        .to eq(Digest::SHA256.hexdigest("root:#{File.join(@tmp, "ghost")}"))
    end
  end

  describe ".for_user" do
    let(:paths) do
      Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@tmp, "state"),
                             "XDG_CONFIG_HOME" => File.join(@tmp, "config"), "HOME" => @tmp })
    end

    def user_config(body)
      FileUtils.mkdir_p(File.dirname(paths.user_config))
      File.write(paths.user_config, body)
    end

    it "does not vouch for a project copy of the same bytes" do
      user_config("middleware { }\n")
      voucher = described_class.for_user(paths:)
      voucher.grant!
      copy = trust_for(project("copy", "config.rb" => "middleware { }\n"))

      expect { copy.require!(vouched_by: voucher) }.to raise_error(described_class::Untrusted)
    end

    it "judges the user's config.rb by its bytes" do
      user_config("middleware { }\n")

      expect(described_class.for_user(paths:).sources).to eq(paths.user_config => "middleware { }\n")
    end

    it "is not trusted by a project mark over identical bytes" do
      user_config("middleware { }\n")
      trust_for(project("app", "config.rb" => "middleware { }\n")).grant!

      expect(described_class.for_user(paths:)).not_to be_trusted
    end

    it "is trusted once its own mark is granted" do
      user_config("middleware { }\n")
      described_class.for_user(paths:).grant!

      expect(described_class.for_user(paths:)).to be_trusted
    end

    it "refuses, naming the file, that it runs in every project, and `lain trust --user`" do
      user_config("middleware { }\n")

      expect { described_class.for_user(paths:).require! }.to raise_error(described_class::Untrusted) { |error|
        expect(error.message).to include(paths.user_config).and include("every project")
          .and include("lain trust --user")
      }
    end

    it "has nothing to judge when there is no user config.rb" do
      expect([described_class.for_user(paths:).sources, described_class.for_user(paths:).trusted?])
        .to eq([{}, true])
    end

    it "reads no bytes from a user config.rb that is a directory" do
      FileUtils.mkdir_p(paths.user_config)

      expect(described_class.for_user(paths:).sources).to eq({})
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

  describe ".legible" do
    it "escapes the invisible format characters a name could hide behind" do
      expect(described_class.legible("a\u200Bb\u200Ec")).to eq("a\\u200Bb\\u200Ec")
    end

    it "keeps a newline" do
      expect(described_class.legible("one\ntwo")).to eq("one\ntwo")
    end
  end

  describe "a file name holding a joined emoji" do
    it "reaches the refusal with the joiner unescaped" do
      name = "\u{1F468}\u200D\u{1F469}.rb"
      root = project("app", name => "one\n")

      expect { trust_for(root).require! }.to raise_error(described_class::Untrusted) { |error|
        expect(error.message).to include(name)
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
