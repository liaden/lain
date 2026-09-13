# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Config::Resolved do
  def resolved_in(root) = described_class.for(config_path(root))

  # `Tomlrb.load_file` is the parse, and counting it is the only honest way to
  # ask "was the file read". Watching `File.read` would count the stat this
  # object does on every ask, which is deliberate and is not a parse.
  def watching_parses
    allow(Tomlrb).to receive(:load_file).and_call_original
    yield
    Tomlrb
  end

  # The same wall-clock second, at a nanosecond the given time does not hold.
  def same_second_as(time) = Time.at(time.to_i, time.nsec.zero? ? 1 : 0, :nsec)

  def refusal_from
    yield
    nil
  rescue Lain::Error => e
    e
  end

  describe "the shared parse" do
    it "reads the file once however many tables are asked for" do
      Dir.mktmpdir("lain-resolved") do |root|
        write_config(root, "[epics]\nhome = \"repo\"\n[sensitivity]\ndenied = [\"x\"]\n[shell]\nexclude = [\"y\"]\n")

        seen = watching_parses do
          resolved = resolved_in(root)
          [resolved.config, resolved.sensitivity, resolved.shell_exclusions, resolved.test_layout]
        end

        expect(seen).to have_received(:load_file).with(config_path(root)).once
      end
    end

    it "reads it once across separate asks for the same file" do
      Dir.mktmpdir("lain-resolved") do |root|
        write_config(root, "[epics]\nhome = \"repo\"\n")
        # Warmed first, so the claim is about the memo outliving one object
        # rather than about one object answering twice from its own members.
        resolved_in(root).config

        seen = watching_parses { 3.times { resolved_in(root).config } }

        expect(seen).not_to have_received(:load_file)
      end
    end

    it "keeps two files apart" do
      Dir.mktmpdir("lain-resolved-a") do |one|
        Dir.mktmpdir("lain-resolved-b") do |two|
          write_config(one, "[epics]\nhome = \"repo\"\n")
          write_config(two, "[epics]\nhome = \"xdg\"\n")

          expect([resolved_in(one).config.epics_home, resolved_in(two).config.epics_home]).to eq(%i[repo xdg])
        end
      end
    end
  end

  # A memo is a claim about when the underlying thing can change, and this is
  # the claim: an edit invalidates it, and nothing else has to. `lain chat`
  # outlives an editor session, so a memo that never invalidated would go on
  # serving a widened `[sensitivity]` table's OLD rules for hours, silently.
  describe "what invalidates it" do
    it "re-reads a file that has been edited under it" do
      Dir.mktmpdir("lain-resolved") do |root|
        write_config(root, "[epics]\nhome = \"repo\"\n")
        expect(resolved_in(root).config.epics_home).to eq(:repo)

        write_config(root, "[epics]\nhome = \"xdg\"\n")

        expect(resolved_in(root).config.epics_home).to eq(:xdg)
      end
    end

    # The bootsnap trap, as a spec: a `(mtime-in-seconds, size)` key cannot tell
    # these two files apart, and would serve the first one forever.
    #
    # The same SECOND is FORCED rather than hoped for. Two ordinary writes
    # usually land inside one second and usually pin the nanosecond component --
    # but a pair that straddled a second boundary would pass just as green while
    # testing nothing, and this is the one example carrying the whole
    # cache-correctness claim. `utime` puts the second write back into the first
    # write's second at a nanosecond it cannot share, so every ingredient of the
    # weaker key is provably equal and only the nanosecond differs.
    it "re-reads a same-length edit made inside one second" do
      Dir.mktmpdir("lain-resolved") do |root|
        path = config_path(root)
        write_config(root, "[isolation]\nretain_days = 3\n")
        before = File.stat(path)
        expect(resolved_in(root).config.isolation.retain_days).to eq(3)

        write_config(root, "[isolation]\nretain_days = 9\n")
        File.utime(File.atime(path), same_second_as(before.mtime), path)

        after = File.stat(path)
        expect([after.mtime.to_i, after.size, after.ino]).to eq([before.mtime.to_i, before.size, before.ino])
        expect(after.mtime.nsec).not_to eq(before.mtime.nsec)
        expect(resolved_in(root).config.isolation.retain_days).to eq(9)
      end
    end

    it "notices a file that has appeared" do
      Dir.mktmpdir("lain-resolved") do |root|
        expect(resolved_in(root)).to be_missing

        write_config(root, "[epics]\nhome = \"repo\"\n")

        expect(resolved_in(root).config.epics_home).to eq(:repo)
      end
    end

    it "notices a file that has gone" do
      Dir.mktmpdir("lain-resolved") do |root|
        write_config(root, "[epics]\nhome = \"repo\"\n")
        expect(resolved_in(root).config.epics_home).to eq(:repo)

        File.delete(config_path(root))

        expect(resolved_in(root).config).to eq(Lain::Config.empty)
      end
    end
  end

  describe "absence" do
    it "is every table at its default rather than an error" do
      Dir.mktmpdir("lain-resolved") do |root|
        resolved = resolved_in(root)

        expect([resolved.config, resolved.sensitivity, resolved.shell_exclusions, resolved.declared_root])
          .to eq([Lain::Config.empty, Lain::Sensitivity::Rules.empty, Lain::Shell::Exclusions.empty, nil])
      end
    end

    it "never opens the file" do
      Dir.mktmpdir("lain-resolved") do |root|
        seen = watching_parses { resolved_in(root).config }

        expect(seen).not_to have_received(:load_file)
      end
    end
  end

  # The posture split, at the level the parse is shared: one parse, three
  # interpreters. A table this class does not read is somebody else's to grow;
  # a key inside one it DOES read is a typo, and loud.
  describe "a granting table" do
    it "tolerates a whole table this class does not read" do
      Dir.mktmpdir("lain-resolved") do |root|
        write_config(root, "[chat_ux]\ntheme = \"green\"\n[epics]\nhome = \"repo\"\n")

        expect(resolved_in(root).config.epics_home).to eq(:repo)
      end
    end

    # Refused HERE and degraded to a notice by {Project::Consent.for}, which is
    # where the granting posture actually lives -- pinned in that class's spec.
    it "refuses a key inside one it does read" do
      Dir.mktmpdir("lain-resolved") do |root|
        write_config(root, "[approval]\nallwo = []\n")

        expect { resolved_in(root).config }.to raise_error(Lain::Config::Refusal, /allwo/)
      end
    end
  end

  describe "a restricting table" do
    it "refuses loudly, naming the file and the table" do
      Dir.mktmpdir("lain-resolved") do |root|
        write_config(root, "sensitivity = \"off\"\n")

        expect { resolved_in(root).sensitivity }
          .to raise_error(Lain::Config::Refusal, /#{Regexp.escape(config_path(root))}.*\[sensitivity\]/)
      end
    end

    # The shared parse's one real hazard, pinned. Every table is built on the
    # reader that asks for it, so a table nobody asked about cannot refuse --
    # which is what stops `[tests]`' degrade in {CLI::Wiring::BoardBuild} from
    # swallowing an `[isolation]` typo and starting a chat whose operator
    # believes a boundary is up.
    it "does not surface another table's refusal" do
      Dir.mktmpdir("lain-resolved") do |root|
        write_config(root, "isolation = \"off\"\n[tests]\npreset = \"rspec\"\n")

        expect { resolved_in(root).test_layout }.not_to raise_error
        expect { resolved_in(root).config }.to raise_error(Lain::Config::Refusal, /\[isolation\]/)
      end
    end
  end

  describe "a file that will not parse" do
    it "refuses every reader by name" do
      Dir.mktmpdir("lain-resolved") do |root|
        write_config(root, "[epics\n")
        resolved = resolved_in(root)

        expect { resolved.config }.to raise_error(Lain::Config::Malformed, /is not valid TOML/)
        expect { resolved.sensitivity }.to raise_error(Lain::Config::Malformed)
        expect { resolved.declared_root }.to raise_error(Lain::Config::Malformed)
      end
    end

    # Remembering the failure is what makes a broken file parse once too. Each
    # degrade path in {CLI::Wiring::BoardBuild} still reports its OWN exception,
    # so the failure is remembered and the refusal is rebuilt.
    it "is parsed once and refused freshly" do
      Dir.mktmpdir("lain-resolved") do |root|
        write_config(root, "[epics\n")
        resolved = resolved_in(root)

        seen = watching_parses do
          @first = refusal_from { resolved.config }
          @second = refusal_from { resolved.sensitivity }
        end

        expect(seen).not_to have_received(:load_file)
        expect(@first.message).to eq(@second.message)
        expect(@first).not_to be(@second)
      end
    end
  end

  describe "the raw table it shares" do
    it "is frozen through, so no reader can change what the next one sees" do
      Dir.mktmpdir("lain-resolved") do |root|
        write_config(root, "[approval]\nallow = [{ tool = \"bash\", input = { command = \"ls\" } }]\n")

        raw = resolved_in(root).raw

        expect { raw["approval"]["allow"].first["tool"] << "!" }.to raise_error(FrozenError)
      end
    end
  end
end
