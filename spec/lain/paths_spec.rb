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

  # The example above passes for a reason that does not generalise, and the
  # generalisation is where the defect came back. {Lain::Paths#present}'s
  # "absolute or ignored" rule guards the XDG variables; `$HOME`'s fallback is
  # `Dir.home`, which on ruby 4.0.6 hands back `$HOME` VERBATIM with no
  # absoluteness check of its own. A fixture env hides that -- it injects a
  # hostile `HOME` while the PROCESS env stays healthy, so `Dir.home` quietly
  # supplies a good answer -- but `Paths.new` defaults `env: ENV`, so in
  # production the same hostile value is read twice and the guard is a no-op.
  #
  # The consequence is not cosmetic: a relative state_home makes
  # {Lain::ProjectDir#state_path} relative, which resolves against the
  # project's cwd, which puts the state feed back inside the user's repository.
  # `with_env`, not an injected Hash, precisely because `Dir.home` is the half
  # an injected Hash cannot reach.
  describe "a $HOME that is not absolute" do
    # The XDG variables are cleared alongside `$HOME`, never inherited from
    # whatever box is running this. Every accessor below reaches the `$HOME`
    # fallback -- and so the guard -- ONLY while its own variable is unset:
    # {Lain::Paths#xdg_dir} returns an absolute `$XDG_CONFIG_HOME` verbatim and
    # never consults `#home` at all. A box that exports one (CI does) therefore
    # saw `config_home` answer instead of refuse, which is how this was found:
    # green on a developer's machine, red on every runner.
    def with_hostile_home(value, &)
      with_env({ "HOME" => value, "XDG_CONFIG_HOME" => nil,
                 "XDG_CACHE_HOME" => nil, "XDG_STATE_HOME" => nil }, &)
    end

    it "refuses a relative HOME rather than answering a relative state_home" do
      with_hostile_home("rel") do
        expect { described_class.new.state_home }
          .to raise_error(described_class::NonAbsoluteHome, /HOME/)
      end
    end

    it "refuses a HOME of `.`, which would resolve against whatever cwd is" do
      with_hostile_home(".") do
        expect { described_class.new.state_home }.to raise_error(described_class::NonAbsoluteHome)
      end
    end

    # Empty is the worst of the three: `File.join("", ".local/state")` is
    # `/.local/state`, the filesystem ROOT, which fails with EACCES at write
    # time and names no cause a human can act on.
    it "refuses an empty HOME rather than anchoring at the filesystem root" do
      with_hostile_home("") do
        expect { described_class.new.state_home }.to raise_error(described_class::NonAbsoluteHome)
      end
    end

    it "names the offending value and the variable to fix" do
      with_hostile_home("rel") do
        expect { described_class.new.home }
          .to raise_error(described_class::NonAbsoluteHome, /"rel"/)
      end
    end

    # The refusal is on the value, not on the accessor: an injected env still
    # wins when it is absolute, and that is the whole substitutability seam.
    it "accepts an absolute injected HOME while the process HOME is hostile" do
      with_hostile_home("rel") do
        expect(described_class.new(env: { "HOME" => "/home/nobody" }).state_home)
          .to eq("/home/nobody/.local/state/lain")
      end
    end

    # Every XDG accessor shares the fallback, so every one of them shared the
    # bug; the guard is in {Lain::Paths#home}, once, rather than in each of the
    # three.
    it "guards config_home and cache_home by the same rule" do
      with_hostile_home("rel") do
        expect { described_class.new.config_home }.to raise_error(described_class::NonAbsoluteHome)
        expect { described_class.new.cache_home }.to raise_error(described_class::NonAbsoluteHome)
      end
    end

    # The line between this refusal and {Lain::Project::Resolver::UnusableHome},
    # pinned rather than left to two docstrings to agree by hand. `/` is a real
    # join base -- it is what root gets in a container -- so this class takes
    # it; it is NOT a usable walk stop, because a root of `/` makes every
    # directory a project, so the resolver refuses the same value.
    it "accepts a HOME of `/`, which the project resolver refuses" do
      with_hostile_home("/") do
        expect(described_class.new.state_home).to eq("/.local/state/lain")
        expect { Lain::Project::Resolver.new(home: "/", paths: described_class.new) }
          .to raise_error(Lain::Project::Resolver::UnusableHome)
      end
    end
  end

  # {#home}'s tolerant twin, for the four callers that hand a possibly-nil
  # home on to {Lain::Project::Resolver} and let IT name the refusal.
  describe "#home_or_nil" do
    def with_hostile_home(value, &)
      with_env({ "HOME" => value, "XDG_CONFIG_HOME" => nil, "XDG_CACHE_HOME" => nil, "XDG_STATE_HOME" => nil }, &)
    end

    it "answers nothing, and raises nothing, when HOME is unusable" do
      with_hostile_home("rel") do
        expect { expect(described_class.new.home_or_nil).to be_nil }.not_to raise_error
      end
    end

    it "answers the injected env's HOME when it is absolute, never the process HOME" do
      with_hostile_home("rel") do
        expect(described_class.new(env: { "HOME" => "/home/nobody" }).home_or_nil).to eq("/home/nobody")
      end
    end

    it "reads the same absolute value #home would, for a healthy env" do
      expect(paths.home_or_nil).to eq(paths.home)
    end

    # The container case: no passwd entry for the running uid, so `Dir.home`
    # itself raises rather than answering. This is what actually
    # distinguishes this method from `present(env) || present(Dir.home)` --
    # without the rescue, this example is the one that catches it.
    it "answers nothing when Dir.home itself raises, rather than leaking the ArgumentError" do
      allow(Dir).to receive(:home).and_raise(ArgumentError, "user 1000 doesn't exist")

      expect(described_class.new(env: {}).home_or_nil).to be_nil
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

    # The hash_agreement probe, pinned: nvim's getcwd() and Ruby's Dir.pwd
    # are both KERNEL-resolved, so a symlinked path ARGUMENT (--project
    # <symlink>) must hash post-resolution too, or it names a different
    # socket/session id than the editor actually serves.
    it "hashes a symlinked directory identically to its kernel-resolved target" do
      require "digest"
      Dir.mktmpdir do |real|
        link = "#{real}-link"
        File.symlink(real, link)

        expect(paths.project_hash(link)).to eq(paths.project_hash(real))
        expect(paths.project_hash(link)).to eq(Digest::SHA256.hexdigest(File.realpath(real))[0, 12])
      ensure
        File.unlink(link) if File.symlink?(link)
      end
    end

    # Isolation (Worktree/Compose/DbIndex) keys WORKER IDS through this method
    # -- strings that name no real path -- so an unresolvable argument falls
    # back to plain lexical expansion instead of raising.
    it "falls back to lexical expansion for a path that does not exist" do
      require "digest"
      expected = Digest::SHA256.hexdigest(File.expand_path("no/such/worker-7"))[0, 12]

      expect(paths.project_hash("no/such/worker-7")).to eq(expected)
    end
  end

  # The recipe every durable per-project artifact is named by. It lives here,
  # beside the two readers that compose it, and {Lain::ProjectDir#container} is
  # the door for a caller holding a project root rather than a key. Eight
  # expressions wrote it out by hand before this method.
  describe "#container" do
    it "composes state_home, the kind and the key" do
      expect(paths("XDG_STATE_HOME" => "/xdg").container("epics", key: "deadbeef1234"))
        .to eq("/xdg/lain/epics/deadbeef1234")
    end

    it "creates nothing, unlike #sessions_dir" do
      Dir.mktmpdir do |tmp|
        state = File.join(tmp, "state")
        paths("XDG_STATE_HOME" => state).container("epics", key: "deadbeef1234")

        expect(File.exist?(state)).to be(false)
      end
    end

    # Required, not defaulted: this class knows the recipe and the caller knows
    # what identifies its project inside a kind -- which is how the consent
    # store's full-width digest and the gc journals' flattened filename both
    # read at the call rather than as exceptions hidden in a default.
    it "takes a key that is a filename rather than a directory" do
      expect(paths("XDG_STATE_HOME" => "/xdg").container("gc", key: "worktrees-abc.stamp"))
        .to eq("/xdg/lain/gc/worktrees-abc.stamp")
    end

    it "is what #sessions_dir is composed from" do
      Dir.mktmpdir do |tmp|
        p = paths("XDG_STATE_HOME" => tmp)

        expect(p.sessions_dir(project: "deadbeef1234"))
          .to eq(p.container("sessions", key: "deadbeef1234"))
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

  # The ephemeral (--btw) session convention. The header is write-once, so
  # ephemerality lives in the FILENAME: <ts>-<pid>.btw.ndjson. Promotion is a
  # File.rename of WAL then journal (same directory), which keeps the owning
  # appender's fd valid; a clean unpromoted exit reaps both files; a crash
  # leaves both for salvage (nothing to spec: no code runs).
  describe "the ephemeral (--btw) filename convention" do
    describe ".ephemeral_for / .ephemeral? / .promoted_for" do
      it "marks a session path by inserting .btw before .ndjson" do
        expect(described_class.ephemeral_for("/s/20260101T000000-1.ndjson"))
          .to eq("/s/20260101T000000-1.btw.ndjson")
      end

      it "recognizes the mark" do
        expect(described_class.ephemeral?("/s/20260101T000000-1.btw.ndjson")).to be(true)
        expect(described_class.ephemeral?("/s/20260101T000000-1.ndjson")).to be(false)
      end

      it "strips the mark for promotion" do
        expect(described_class.promoted_for("/s/20260101T000000-1.btw.ndjson"))
          .to eq("/s/20260101T000000-1.ndjson")
      end

      it "refuses to promote a name that carries no mark, loudly" do
        expect { described_class.promoted_for("/s/20260101T000000-1.ndjson") }
          .to raise_error(ArgumentError, /btw/)
      end

      it "refuses to double-mark, loudly" do
        expect { described_class.ephemeral_for("/s/a.btw.ndjson") }.to raise_error(ArgumentError, /btw/)
      end

      it "derives a wal that carries the mark, so the pair travels together" do
        expect(described_class.wal_for("/s/a.btw.ndjson")).to eq("/s/a.btw.wal")
      end
    end

    describe Lain::Paths::Ephemeral do
      around do |example|
        Dir.mktmpdir { |dir| @dir = dir and example.run }
      end

      let(:journal_path) { File.join(@dir, "20260101T000000-1.btw.ndjson") }
      let(:wal_path) { File.join(@dir, "20260101T000000-1.btw.wal") }
      let(:header_bytes) { "{\"type\":\"session\"}\n" }

      before do
        File.write(journal_path, header_bytes)
        File.write(wal_path, "frame-bytes")
      end

      def recording_fs(log)
        fs = Object.new
        fs.define_singleton_method(:rename) { |from, to| log << [from, to] and File.rename(from, to) }
        fs.define_singleton_method(:exist?) { |path| File.exist?(path) }
        fs.define_singleton_method(:delete) { |path| File.delete(path) }
        fs
      end

      it "refuses a non-ephemeral path, loudly" do
        expect { described_class.new(File.join(@dir, "a.ndjson")) }.to raise_error(ArgumentError, /btw/)
      end

      describe "#promote!" do
        it "renames the WAL FIRST, then the journal, in the same directory" do
          log = []

          promoted = described_class.new(journal_path, filesystem: recording_fs(log)).promote!

          expect(log).to eq([[wal_path, File.join(@dir, "20260101T000000-1.wal")],
                             [journal_path, promoted]])
          expect(promoted).to eq(File.join(@dir, "20260101T000000-1.ndjson"))
          expect(File.exist?(journal_path)).to be(false)
          expect(File.exist?(wal_path)).to be(false)
        end

        it "leaves the header bytes untouched -- identity moved, record did not" do
          promoted = described_class.new(journal_path).promote!

          expect(File.binread(promoted)).to eq(header_bytes)
          expect(File.binread(Lain::Paths.wal_for(promoted))).to eq("frame-bytes")
        end

        it "keeps the owning appender's fd valid across the rename" do
          promoted = File.open(journal_path, "ab") do |handle|
            described_class.new(journal_path).promote!.tap { handle.write("{\"type\":\"turn\"}\n") }
          end

          expect(File.binread(promoted)).to eq("#{header_bytes}{\"type\":\"turn\"}\n")
        end

        it "promotes a journal that never spooled a WAL (the .wal opens lazily)" do
          File.delete(wal_path)

          promoted = described_class.new(journal_path).promote!

          expect(File.exist?(promoted)).to be(true)
          expect(File.exist?(File.join(@dir, "20260101T000000-1.wal"))).to be(false)
        end

        # The pinned crash window: dying between the two renames must leave an
        # ephemeral-NAMED journal (visibly half-done, retryable) -- never a
        # promoted .ndjson whose recorded frames sit in a wal basename that no
        # longer matches Paths.wal_for.
        it "a crash between the renames leaves the .btw journal, never a wal-less promoted name" do
          crashing = Object.new
          crashing.define_singleton_method(:exist?) { |path| File.exist?(path) }
          crashing.define_singleton_method(:rename) do |from, to|
            raise "power loss" if to.end_with?(".ndjson")

            File.rename(from, to)
          end

          expect { described_class.new(journal_path, filesystem: crashing).promote! }.to raise_error(/power loss/)

          expect(File.exist?(journal_path)).to be(true)
          expect(File.exist?(File.join(@dir, "20260101T000000-1.ndjson"))).to be(false)
          expect(File.exist?(File.join(@dir, "20260101T000000-1.wal"))).to be(true)

          # ... and the retry completes: the wal leg is already done, so only
          # the journal rename remains.
          promoted = described_class.new(journal_path).promote!
          expect(File.exist?(promoted)).to be(true)
          expect(File.exist?(File.join(@dir, "20260101T000000-1.wal"))).to be(true)
        end
      end

      # POSIX File.rename silently replaces its
      # target -- promotion onto names an unrelated durable session already
      # owns would DESTROY that record. One exist? guard each, both checked
      # before any rename runs, so a refused promotion changes nothing.
      describe "#promote! collision guards" do
        let(:durable_journal) { File.join(@dir, "20260101T000000-1.ndjson") }
        let(:durable_wal) { File.join(@dir, "20260101T000000-1.wal") }

        it "refuses to promote onto an existing journal, destroying nothing" do
          File.write(durable_journal, "UNRELATED DURABLE RECORD")

          expect { described_class.new(journal_path).promote! }
            .to raise_error(Lain::Paths::Ephemeral::Collision, /20260101T000000-1\.ndjson/)

          expect(File.read(durable_journal)).to eq("UNRELATED DURABLE RECORD")
          expect(File.exist?(journal_path)).to be(true)
          expect(File.exist?(wal_path)).to be(true)
        end

        it "refuses to promote onto an existing wal, before any rename runs" do
          File.write(durable_wal, "DURABLE FRAMES")

          expect { described_class.new(journal_path).promote! }
            .to raise_error(Lain::Paths::Ephemeral::Collision, /20260101T000000-1\.wal/)

          expect(File.read(durable_wal)).to eq("DURABLE FRAMES")
          expect(File.exist?(journal_path)).to be(true)
          expect(File.exist?(wal_path)).to be(true)
        end

        it "raises loudly on a double promotion (probe 4c) -- the promoted pair already owns the names" do
          described_class.new(journal_path).promote!

          expect { described_class.new(journal_path).promote! }
            .to raise_error(Lain::Paths::Ephemeral::Collision)
        end
      end

      it "reap! after promote! is a silent no-op -- a stale reap cannot touch the promoted record (probe 4e)" do
        ephemeral = described_class.new(journal_path)
        promoted = ephemeral.promote!

        ephemeral.reap!

        expect(File.exist?(promoted)).to be(true)
        expect(File.exist?(Lain::Paths.wal_for(promoted))).to be(true)
      end

      describe "#reap!" do
        it "deletes journal and WAL on a clean unpromoted exit" do
          described_class.new(journal_path).reap!

          expect(File.exist?(journal_path)).to be(false)
          expect(File.exist?(wal_path)).to be(false)
        end

        it "tolerates the lazily-absent wal" do
          File.delete(wal_path)

          described_class.new(journal_path).reap!

          expect(File.exist?(journal_path)).to be(false)
        end
      end
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
