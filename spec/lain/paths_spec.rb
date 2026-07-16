# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Paths do
  # Every scenario builds its own env Hash -- injected via `env:`, never mutating the
  # real ENV -- so the suite never reads or writes the real $HOME.
  def paths(overrides = {})
    described_class.new(env: { "HOME" => "/home/nobody" }.merge(overrides))
  end

  describe "XDG variables win" do
    it "uses XDG_CONFIG_HOME, suffixed with /lain" do
      expect(paths("XDG_CONFIG_HOME" => "/x").config_home).to eq("/x/lain")
    end

    it "uses XDG_CACHE_HOME, suffixed with /lain" do
      expect(paths("XDG_CACHE_HOME" => "/x").cache_home).to eq("/x/lain")
    end

    it "uses XDG_STATE_HOME, suffixed with /lain, and sessions_dir starts with it" do
      Dir.mktmpdir do |tmp|
        state_home = File.join(tmp, "x")
        p = paths("XDG_STATE_HOME" => state_home)

        expect(p.state_home).to eq("#{state_home}/lain")
        expect(p.sessions_dir(project: "abc123")).to start_with(p.state_home)
      end
    end

    it "uses XDG_RUNTIME_DIR, suffixed with /lain" do
      expect(paths("XDG_RUNTIME_DIR" => "/run/user/1000").runtime_dir).to eq("/run/user/1000/lain")
    end
  end

  describe "fallbacks are the XDG-spec defaults" do
    it "falls back config_home to $HOME/.config/lain" do
      expect(paths.config_home).to eq("/home/nobody/.config/lain")
    end

    it "falls back cache_home to $HOME/.cache/lain" do
      expect(paths.cache_home).to eq("/home/nobody/.cache/lain")
    end

    it "falls back state_home to $HOME/.local/state/lain" do
      expect(paths.state_home).to eq("/home/nobody/.local/state/lain")
    end

    it "falls back runtime_dir to /tmp/lain" do
      expect(paths.runtime_dir).to eq("/tmp/lain")
    end

    it "treats an empty XDG var the same as unset" do
      expect(paths("XDG_STATE_HOME" => "").state_home).to eq("/home/nobody/.local/state/lain")
    end

    # The XDG Base Directory spec: a non-absolute value is invalid and MUST be
    # ignored -- otherwise "relative/path" silently anchors to whatever cwd is.
    it "treats a relative XDG var as unset" do
      expect(paths("XDG_STATE_HOME" => "relative/path").state_home).to eq("/home/nobody/.local/state/lain")
    end

    it "does not anchor to filesystem root when HOME is blank" do
      expect(paths("HOME" => "").state_home).to eq(File.join(Dir.home, ".local/state/lain"))
    end
  end

  describe "#project_hash" do
    it "is a stable 12-hex-char digest of the expanded cwd" do
      first = paths.project_hash("/some/project")
      second = paths.project_hash("/some/project")

      expect(first).to eq(second)
      expect(first).to match(/\A[0-9a-f]{12}\z/)
    end

    it "differs for a different directory" do
      expect(paths.project_hash("/some/project")).not_to eq(paths.project_hash("/other/project"))
    end

    it "matches the DEBUGGING_NVIM sha256[:12] recipe" do
      require "digest"
      expected = Digest::SHA256.hexdigest(File.expand_path("/some/project"))[0, 12]

      expect(paths.project_hash("/some/project")).to eq(expected)
    end

    it "defaults to the current working directory" do
      Dir.mktmpdir do |tmp|
        Dir.chdir(tmp) { expect(paths.project_hash).to eq(paths.project_hash(tmp)) }
      end
    end
  end

  describe "#sessions_dir" do
    it "nests under state_home/sessions/<project-hash> and creates it" do
      Dir.mktmpdir do |tmp|
        p = paths("XDG_STATE_HOME" => tmp)
        dir = p.sessions_dir(project: "deadbeef1234")

        expect(dir).to eq("#{tmp}/lain/sessions/deadbeef1234")
        expect(Dir.exist?(dir)).to be(true)
      end
    end

    it "defaults project: to the current project_hash" do
      Dir.mktmpdir do |tmp|
        p = paths("XDG_STATE_HOME" => tmp)
        expect(p.sessions_dir).to eq("#{tmp}/lain/sessions/#{p.project_hash}")
      end
    end
  end

  describe ".wal_for" do
    it "derives <session-stem>.wal beside the given NDJSON path" do
      expect(described_class.wal_for("/x/lain/sessions/proj/20260101T000000-1.ndjson"))
        .to eq("/x/lain/sessions/proj/20260101T000000-1.wal")
    end

    it "strips whatever extension the given path carries, not a hardcoded .ndjson" do
      expect(described_class.wal_for("/tmp/session.json")).to eq("/tmp/session.wal")
    end

    it "is the ONE authority both Chronicle#spool and Salvager#wal_path delegate to" do
      chronicle = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: StringIO.new),
                                           journal_path: "/x/lain/sessions/proj/a.ndjson")
      expect(chronicle.send(:wal_path)).to eq(described_class.wal_for("/x/lain/sessions/proj/a.ndjson"))

      salvager = Lain::CLI::Resume::Salvager.new(path: "/x/lain/sessions/proj/a.ndjson", timeline: nil)
      expect(salvager.send(:wal_path)).to eq(described_class.wal_for("/x/lain/sessions/proj/a.ndjson"))
    end
  end

  describe "an unwritable target refuses namedly" do
    it "raises Lain::Paths::Unwritable naming the path" do
      Dir.mktmpdir do |tmp|
        File.chmod(0o500, tmp) # read+execute, no write -- can't mkdir a child
        p = paths("XDG_STATE_HOME" => tmp)

        expect { p.sessions_dir(project: "x") }
          .to raise_error(described_class::Unwritable, /#{Regexp.escape(tmp)}/)
      ensure
        File.chmod(0o700, tmp) # so Dir.mktmpdir's own cleanup can remove it
      end
    end
  end
end
