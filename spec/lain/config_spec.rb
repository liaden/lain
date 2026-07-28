# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Config do
  # Every scenario builds its own throwaway root -- .lain/config.toml is a
  # project file, never the real cwd's, so the suite never reads or writes a
  # config that could affect any other spec.
  def write_config(root, body)
    FileUtils.mkdir_p(File.join(root, ".lain"))
    File.write(File.join(root, ".lain", "config.toml"), body)
  end

  def config_path(root) = File.join(root, ".lain", "config.toml")

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
          expect(error.message).to match(/could not be read as TOML/)
          expect(error.message).not_to match(/is not valid TOML/)
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
          expect(error.message).to match(/could not be read as TOML/)
          expect(error.message).not_to match(/is not valid TOML/)
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
          expect(error.message).to match(/could not be read as TOML/)
          expect(error.message).not_to match(/is not valid TOML/)
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

  describe "a typo inside [epics] is loud" do
    it "names the unknown key and the known keys" do
      Dir.mktmpdir do |root|
        write_config(root, <<~TOML)
          [epics]
          hoem = "repo"
        TOML

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Epics::UnknownKeys, /hoem/)
      end
    end

    it "carries the path and the offending key on the raised error" do
      Dir.mktmpdir do |root|
        write_config(root, <<~TOML)
          [epics]
          hoem = "repo"
        TOML

        expect { described_class.load(root:) }.to raise_error do |error|
          expect(error.path).to eq(config_path(root))
          expect(error.keys).to eq(["hoem"])
        end
      end
    end

    # Panel probe: two typos in the same file used to report only the first
    # (`unknown.first`), forcing a second run to find the second.
    it "names every unknown key in one pass, not just the first" do
      Dir.mktmpdir do |root|
        write_config(root, <<~TOML)
          [epics]
          zzz = 1
          aaa = 2
        TOML

        expect { described_class.load(root:) }.to raise_error do |error|
          expect(error.keys).to contain_exactly("zzz", "aaa")
        end
      end
    end

    # Panel review round 2: now that one error can report several keys, the
    # message noun has to agree -- "has no key zzz, aaa" reads as though only
    # one were wrong.
    it "pluralizes the message noun when it reports more than one key" do
      Dir.mktmpdir do |root|
        write_config(root, <<~TOML)
          [epics]
          zzz = 1
          aaa = 2
        TOML

        expect { described_class.load(root:) }.to raise_error(/no keys/)
      end
    end

    # Panel probe: `[epics.sub]` parses to a nested Hash under the "sub" key --
    # still an unrecognized key, not a different code path.
    it "refuses a nested [epics.sub] table as an unknown key" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics.sub]\nk = 1\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Epics::UnknownKeys, /sub/)
      end
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

  describe "[epics] present but empty" do
    it "still defaults epics_home" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics]\n")

        expect(described_class.load(root:).epics_home).to eq(:xdg)
      end
    end
  end

  describe "#epics_home" do
    it "reads :repo when the table says repo" do
      Dir.mktmpdir do |root|
        write_config(root, <<~TOML)
          [epics]
          home = "repo"
        TOML

        expect(described_class.load(root:).epics_home).to eq(:repo)
      end
    end

    it "reads :repo across CRLF line endings" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics]\r\nhome = \"repo\"\r\n")

        expect(described_class.load(root:).epics_home).to eq(:repo)
      end
    end

    it "refuses any value other than xdg or repo, naming both allowed values" do
      Dir.mktmpdir do |root|
        write_config(root, <<~TOML)
          [epics]
          home = "somewhere_else"
        TOML

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Epics::InvalidHome, /somewhere_else/) do |error|
            expect(error.message).to match(/xdg/)
            expect(error.message).to match(/repo/)
          end
      end
    end

    it "refuses an empty string, naming both allowed values" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics]\nhome = \"\"\n")

        expect { described_class.load(root:) }.to raise_error(Lain::Config::Epics::InvalidHome)
      end
    end

    # Panel Blocker 1: a wrong-TYPED value used to crash inside `#to_sym`
    # instead of refusing -- and it is not even a Lain::Error, so
    # exe/lain's Lain::Error -> Thor::Error mapping misses it entirely.
    %w[3 true].each do |literal|
      it "refuses #{literal} (wrong type) the same way it refuses a bad string" do
        Dir.mktmpdir do |root|
          write_config(root, "[epics]\nhome = #{literal}\n")

          expect { described_class.load(root:) }
            .to raise_error(Lain::Config::Epics::InvalidHome) do |error|
              expect(error.message).to match(/xdg/)
              expect(error.message).to match(/repo/)
            end
        end
      end
    end

    it "refuses an array the same way it refuses a bad string" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics]\nhome = [\"repo\"]\n")

        expect { described_class.load(root:) }.to raise_error(Lain::Config::Epics::InvalidHome)
      end
    end

    it "carries the path and the offending value on the raised error" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics]\nhome = 3\n")

        expect { described_class.load(root:) }.to raise_error do |error|
          expect(error.path).to eq(config_path(root))
          expect(error.value).to eq(3)
        end
      end
    end
  end

  # The collaborator the panel asked to be extracted: Config locates the
  # file and dispatches to it, but validating [epics]'s own shape is this
  # class's job, exercised directly rather than only ever through Config.load.
  describe Lain::Config::Epics do
    it "defaults home to :xdg for an empty table" do
      expect(described_class.from({}, path: "/irrelevant").home).to eq(:xdg)
    end

    it "treats a nil table (the key absent from the parsed TOML) the same as empty" do
      expect(described_class.from(nil, path: "/irrelevant").home).to eq(:xdg)
    end

    # Panel review round 2: Epics.new bypasses .from entirely, so the closed
    # set has to be enforced in the value's own constructor too -- T1's
    # Epic::Issue does exactly this, and this whole wave's blockers were all
    # variants of "constructs fine, fails later" (T9 is specified to `case`
    # on epics_home, so a value that skipped this check would reach it live).
    it "refuses a value outside the closed set at construction, not just through .from" do
      expect { described_class.new(home: :bogus) }.to raise_error(Lain::Config::Epics::InvalidHome, /bogus/)
    end
  end

  describe "Config.empty" do
    it "is deeply frozen" do
      expect(described_class.empty).to be_deeply_frozen
    end

    it "is Ractor-shareable" do
      expect(Ractor.shareable?(described_class.empty)).to be(true)
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
  end
end
