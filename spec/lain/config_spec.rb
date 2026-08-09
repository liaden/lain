# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Config do
  describe "absence is all defaults" do
    it "resolves epics_home to :xdg without raising" do
      Dir.mktmpdir do |root|
        config = described_class.load(root:)

        expect(config.epics_home).to eq(:xdg)
      end
    end

    it "is the same value .empty returns" do
      Dir.mktmpdir do |root|
        expect(described_class.load(root:)).to eq(described_class.empty)
      end
    end
  end

  describe "malformed TOML" do
    it "raises Config::Malformed naming the path" do
      Dir.mktmpdir do |root|
        write_config(root, "this is not [valid toml")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Malformed, /#{Regexp.escape(config_path(root))}/)
      end
    end

    # A genuine TOML syntax error IS honestly described as "not valid TOML" --
    # tomlrb actually tried to parse it and choked. This is the control case
    # for the wording fix below: only the "never even read" causes lose that
    # clause.
    it "says 'is not valid TOML' for an actual syntax error" do
      Dir.mktmpdir do |root|
        write_config(root, "this is not [valid toml")

        expect { described_class.load(root:) }.to raise_error(/is not valid TOML/)
      end
    end

    # Panel probe: tomlrb's lexer raises ArgumentError (not ParseError) on
    # invalid bytes -- a distinct Ruby exception class the original rescue
    # clause did not catch at all.
    it "raises Config::Malformed on invalid UTF-8 bytes, not a raw ArgumentError" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, ".lain"))
        File.binwrite(config_path(root), "[epics]\nhome = \"\xFF\xFE\"\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Malformed, /#{Regexp.escape(config_path(root))}/)
      end
    end

    # Panel review round 2: the file was never successfully READ in any of
    # these three cases, so "is not valid TOML" is a lie about what happened --
    # only a genuine parse failure earns that phrase.
    it "does not claim invalid UTF-8 bytes are 'not valid TOML' -- the file was never read" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, ".lain"))
        File.binwrite(config_path(root), "[epics]\nhome = \"\xFF\xFE\"\n")

        expect { described_class.load(root:) }.to raise_error do |error|
          expect(error.message).to include("could not be read as TOML")
          expect(error.message).not_to include("is not valid TOML")
        end
      end
    end

    # Panel probe: an unreadable file raises Errno::EACCES (a SystemCallError),
    # not ParseError -- also uncaught before this fix.
    it "raises Config::Malformed on a permission-denied file" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics]\nhome = \"repo\"\n")
        path = config_path(root)
        File.chmod(0o000, path)

        expect { described_class.load(root:) }.to raise_error(Lain::Config::Malformed)
      ensure
        File.chmod(0o600, path) if path && File.exist?(path)
      end
    end

    it "does not claim a permission-denied file is 'not valid TOML' -- it was never read" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics]\nhome = \"repo\"\n")
        path = config_path(root)
        File.chmod(0o000, path)

        expect { described_class.load(root:) }.to raise_error do |error|
          expect(error.message).to include("could not be read as TOML")
          expect(error.message).not_to include("is not valid TOML")
        end
      ensure
        File.chmod(0o600, path) if path && File.exist?(path)
      end
    end

    # Panel probe: config.toml itself being a directory raises Errno::EISDIR.
    it "raises Config::Malformed when config.toml is a directory" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(config_path(root))

        expect { described_class.load(root:) }.to raise_error(Lain::Config::Malformed)
      end
    end

    it "does not claim a directory is 'not valid TOML' -- it was never read" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(config_path(root))

        expect { described_class.load(root:) }.to raise_error do |error|
          expect(error.message).to include("could not be read as TOML")
          expect(error.message).not_to include("is not valid TOML")
        end
      end
    end

    it "carries the path on the raised error, not just in the message" do
      Dir.mktmpdir do |root|
        write_config(root, "this is not [valid toml")

        expect { described_class.load(root:) }.to raise_error do |error|
          expect(error.path).to eq(config_path(root))
        end
      end
    end

    it "does not blow up on a bare raise with no arguments" do
      expect { raise Lain::Config::Malformed }.to raise_error(Lain::Config::Malformed)
    end
  end

  describe "an unknown table is tolerated" do
    it "loads and epics_home is still the default" do
      Dir.mktmpdir do |root|
        write_config(root, <<~TOML)
          [prompt]
          format = "anthropic"
        TOML

        config = described_class.load(root:)

        expect(config.epics_home).to eq(:xdg)
      end
    end

    # Panel Blocker 2: a top-level `epics` that isn't a table (TOML permits a
    # scalar or array there) used to crash on the first `.keys` call with an
    # unnamed NoMethodError instead of refusing loudly.
    it "refuses a top-level epics value that is not a table" do
      Dir.mktmpdir do |root|
        write_config(root, %(epics = "x"\n))

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Epics::NotATable, /must be a table/)
      end
    end
  end

  describe "Config.empty" do
    it "is deeply frozen" do
      expect(described_class.empty).to be_deeply_frozen
    end

    # Panel probe: .empty allocated a fresh instance on every call; a real
    # Null Object is one singleton, not a factory.
    it "is the same object every time, not a fresh allocation" do
      expect(described_class.empty).to equal(described_class.empty)
    end
  end

  describe "equality" do
    it "is symmetric for a subclass instance (instance_of?, not is_a?)" do
      sub = Class.new(described_class)
      a = described_class.empty
      b = sub.new(epics: Lain::Config::Epics.new(home: :xdg))

      expect(a == b).to eq(b == a)
    end

    it "agrees with #hash: equal values never land in different Hash buckets" do
      a = described_class.empty
      b = described_class.new(epics: Lain::Config::Epics.new(home: :xdg))

      expect(a).to eq(b)
      expect({ a => 1 }[b]).to eq(1)
    end

    # A member that equality forgot is a config that compares equal while
    # remembering different answers -- exactly the bug the epics member's own
    # `instance_of?` note is guarding against one field over.
    it "distinguishes two configs that remember different answers" do
      epics = Lain::Config::Epics.new(home: :xdg)
      a = described_class.new(epics:, approval: { "deny_tool" => [{ "tool" => "bash" }] })
      b = described_class.new(epics:)

      expect(a).not_to eq(b)
      expect(a.hash).not_to eq(b.hash)
    end
  end

  # T23. The `[sensitivity]` table is read on its OWN, by {.sensitivity} rather
  # than through {.load}, and that separation is the point rather than an
  # accident of load order: this table RESTRICTS, so it must refuse loudly, and
  # every other table TOLERATES a typo at the cost of its own feature. Reading
  # them together would force one posture on both -- which it did, briefly, and
  # a typo in `[epics]` took `lain chat` down with it.
  describe ".sensitivity" do
    # No working-directory default, unlike {.load}: the caller holds a resolved
    # project root, and defaulting one here is the divergence this chunk exists
    # to remove.
    it "takes its root from the caller rather than the working directory" do
      expect { described_class.sensitivity }.to raise_error(ArgumentError, /root/)
    end

    it "compiles the project's patterns into rules the classifier can hold" do
      Dir.mktmpdir do |root|
        write_config(root, <<~TOML)
          [sensitivity]
          denied = ["*.secret"]
          gated = ["*.private"]
          exempt = [".gitconfig"]
        TOML

        rules = described_class.sensitivity(root:)

        expect([rules.denied.size, rules.gated.size, rules.exempt.size]).to eq([1, 1, 1])
      end
    end

    # Null Object, not nil: an absent table leaves the built-in tables in force,
    # which is the difference between "this project adds nothing" and "this
    # project has no boundary".
    it "answers empty rules when a config file carries no sensitivity table" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics]\nhome = \"repo\"\n")

        expect(described_class.sensitivity(root:)).to eq(Lain::Sensitivity::Rules.empty)
      end
    end

    it "answers empty rules for a root with no config file at all" do
      Dir.mktmpdir do |root|
        expect(described_class.sensitivity(root:)).to eq(Lain::Sensitivity::Rules.empty)
      end
    end

    # THE INDEPENDENCE, in both directions. A broken `[epics]` must not cost the
    # project its path rules, and a broken `[sensitivity]` must not be excused
    # by the rest of the file parsing cleanly.
    it "reads the sensitivity table even when another table is malformed" do
      Dir.mktmpdir do |root|
        write_config(root, %(epics = "not a table"\n\n[sensitivity]\ndenied = ["*.secret"]\n))

        expect { described_class.load(root:) }.to raise_error(Lain::Config::Epics::NotATable)
        expect(described_class.sensitivity(root:).denied.size).to eq(1)
      end
    end

    it "refuses its own bad table even when every other table is fine" do
      Dir.mktmpdir do |root|
        write_config(root, %(sensitivity = "strict"\n\n[epics]\nhome = "repo"\n))

        expect { described_class.load(root:) }.not_to raise_error
        expect { described_class.sensitivity(root:) }.to raise_error(Lain::Sensitivity::Rules::NotATable)
      end
    end

    it "refuses a scalar where the table belongs, naming the file" do
      Dir.mktmpdir do |root|
        write_config(root, %(sensitivity = "strict"\n))

        expect { described_class.sensitivity(root:) }
          .to raise_error(Lain::Sensitivity::Rules::NotATable, /#{Regexp.escape(config_path(root))}/)
      end
    end

    it "refuses a pattern that could never match, naming the file" do
      Dir.mktmpdir do |root|
        write_config(root, "[sensitivity]\ndenied = [\"config/secrets/prod.key\"]\n")

        expect { described_class.sensitivity(root:) }
          .to raise_error(Lain::Sensitivity::Rules::MalformedPattern, /#{Regexp.escape(config_path(root))}/)
      end
    end

    # A file nobody can parse is a file whose sensitivity table nobody can read
    # either, so this one stays a Malformed -- and {CLI::Wiring::BoardBuild} is
    # where that degrades to a notice, because only there is there somebody to
    # tell.
    it "still reports an unparseable file as Malformed" do
      Dir.mktmpdir do |root|
        write_config(root, "this is not [valid toml")

        expect { described_class.sensitivity(root:) }.to raise_error(Lain::Config::Malformed)
      end
    end
  end
end
