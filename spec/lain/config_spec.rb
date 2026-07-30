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
            expect(error.message).to include("xdg")
            expect(error.message).to include("repo")
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
              expect(error.message).to include("xdg")
              expect(error.message).to include("repo")
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

  # `[epics.gates]` maps an epic stage to the gate policy it runs under. Both
  # sides of the mapping are closed sets, so both are refused at load with the
  # same UnknownKeys posture the parent table already carries.
  describe "[epics.gates]" do
    it "reads a policy per stage" do
      Dir.mktmpdir do |root|
        write_config(root, <<~TOML)
          [epics.gates]
          research = "hands_off"
          epic_plan = "deferred"
        TOML

        config = described_class.load(root:)

        expect(config.gate_policy_for("research")).to eq("hands_off")
        expect(config.gate_policy_for("epic_plan")).to eq("deferred")
      end
    end

    it "leaves a stage the table does not name interactive" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics.gates]\nresearch = \"hands_off\"\n")

        expect(described_class.load(root:).gate_policy_for("issue_plan")).to eq("interactive")
      end
    end

    it "is interactive everywhere when the table is absent" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics]\nhome = \"repo\"\n")

        policies = Lain::Epic::STAGES.map { |stage| described_class.load(root:).gate_policy_for(stage) }

        expect(policies).to all(eq("interactive"))
      end
    end

    it "is interactive everywhere with no config file at all" do
      Dir.mktmpdir do |root|
        expect(described_class.load(root:).gate_policy_for("research")).to eq("interactive")
      end
    end

    it "coexists with home in the same [epics] table" do
      Dir.mktmpdir do |root|
        write_config(root, <<~TOML)
          [epics]
          home = "repo"

          [epics.gates]
          research = "hands_off"
        TOML

        config = described_class.load(root:)

        expect(config.epics_home).to eq(:repo)
        expect(config.gate_policy_for("research")).to eq("hands_off")
      end
    end

    it "refuses a typo in a stage name, naming the unknown key" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics.gates]\nreserch = \"deferred\"\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Epics::Gates::UnknownStages, /reserch/)
      end
    end

    it "names the pipeline it expected, so the typo is fixable from the message" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics.gates]\nreserch = \"deferred\"\n")

        expect { described_class.load(root:) }.to raise_error(/research/)
      end
    end

    it "names every unknown stage in one pass, not just the first" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics.gates]\nzzz = \"deferred\"\naaa = \"deferred\"\n")

        expect { described_class.load(root:) }.to raise_error do |error|
          expect(error.keys).to contain_exactly("zzz", "aaa")
        end
      end
    end

    it "refuses an unknown policy name, naming it and the known policies" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics.gates]\nresearch = \"yolo\"\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Epics::Gates::UnknownPolicies, /yolo/) do |error|
            expect(error.message).to include("hands_off")
            expect(error.message).to include("deferred")
          end
      end
    end

    it "refuses a wrong-typed policy value the same way it refuses a bad string" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics.gates]\nresearch = 3\n")

        expect { described_class.load(root:) }.to raise_error(Lain::Config::Epics::Gates::UnknownPolicies)
      end
    end

    it "refuses a gates value that is not a table" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics]\ngates = \"deferred\"\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Epics::Gates::NotATable, /must be a table/)
      end
    end

    it "carries the path and the offending keys on a gates refusal" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics.gates]\nreserch = \"deferred\"\n")

        expect { described_class.load(root:) }.to raise_error do |error|
          expect(error.path).to eq(config_path(root))
          expect(error.keys).to eq(["reserch"])
        end
      end
    end
  end

  describe Lain::Config::Epics::Gates do
    it "answers interactive for a stage it does not name" do
      expect(described_class.empty.policy_for("research")).to eq("interactive")
    end

    it "answers the same policy for a Stage value as for its name" do
      gates = described_class.new(table: { "research" => "hands_off" })

      expect(gates.policy_for(Lain::Epic::Stage.new("research"))).to eq("hands_off")
    end

    # The Epics#initialize precedent: a value built by any caller that is not
    # `.from` must refuse just as loudly, or a typo could reach the factory.
    it "refuses an unknown stage at construction, not just through .from" do
      expect { described_class.new(table: { "reserch" => "deferred" }) }
        .to raise_error(Lain::Config::Epics::Gates::UnknownStages, /reserch/)
    end

    it "refuses an unknown policy at construction, not just through .from" do
      expect { described_class.new(table: { "research" => "yolo" }) }
        .to raise_error(Lain::Config::Epics::Gates::UnknownPolicies, /yolo/)
    end

    it "refuses a non-table at construction" do
      expect { described_class.new(table: "deferred") }
        .to raise_error(Lain::Config::Epics::Gates::NotATable)
    end

    it "is deeply frozen, so it rides inside a Ractor-shareable Config" do
      expect(described_class.new(table: { "research" => "hands_off" })).to be_deeply_frozen
    end

    it "does not alias the Hash it was handed" do
      table = { "research" => "hands_off" }
      gates = described_class.new(table:)
      table["epic_plan"] = "deferred"

      expect(gates.policy_for("epic_plan")).to eq("interactive")
    end

    # One list, in the factory. Two would drift, and the drift's shape is a
    # config that loads and then refuses to build.
    it "accepts every policy name the factory ships" do
      names = Lain::Approval::Gate::Policies.names
      accepted = names.map { |name| described_class.new(table: { "research" => name }).policy_for("research") }

      expect(accepted).to eq(names)
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

    it "defaults gates to the empty table" do
      expect(described_class.from({}, path: "/irrelevant").gates).to eq(Lain::Config::Epics::Gates.empty)
    end

    it "defaults gates for a value built without one" do
      expect(described_class.new(home: :xdg).gates).to eq(Lain::Config::Epics::Gates.empty)
    end

    # Panel Fix 2: `home` was guarded in this constructor and `gates` was not,
    # so a hand-built value carried a raw Hash and failed later, unnamed, as
    # `NoMethodError: undefined method 'policy_for' for an instance of Hash`
    # from Config#gate_policy_for. Same ground as the `home` guard above.
    it "refuses a hand-built gates table naming a policy nothing builds" do
      expect { described_class.new(home: :xdg, gates: { "research" => "yolo" }) }
        .to raise_error(Lain::Config::Epics::Gates::UnknownPolicies, /yolo/)
    end

    it "refuses a hand-built gates table keyed on a stage that does not exist" do
      expect { described_class.new(home: :xdg, gates: { "reserch" => "deferred" }) }
        .to raise_error(Lain::Config::Epics::Gates::UnknownStages, /reserch/)
    end

    it "coerces a well-formed hand-built table rather than storing the Hash" do
      epics = described_class.new(home: :xdg, gates: { "research" => "hands_off" })

      expect(epics.gates).to eq(Lain::Config::Epics::Gates.new(table: { "research" => "hands_off" }))
    end

    it "reads a hand-built table as an absent one when it is nil" do
      expect(described_class.new(home: :xdg, gates: nil).gates).to eq(Lain::Config::Epics::Gates.empty)
    end

    it "refuses a gates value of the wrong shape entirely" do
      expect { described_class.new(home: :xdg, gates: "deferred") }
        .to raise_error(Lain::Config::Epics::Gates::NotATable)
    end

    # Data#with re-runs #initialize, so the guard has to hold on the copy too.
    it "re-checks gates through #with" do
      expect { described_class.new(home: :xdg).with(gates: { "research" => "yolo" }) }
        .to raise_error(Lain::Config::Epics::Gates::UnknownPolicies)
    end

    it "leaves Config#gate_policy_for total for any value that constructs" do
      config = Lain::Config.new(epics: described_class.new(home: :xdg, gates: { "research" => "hands_off" }))

      expect(config.gate_policy_for("implementation")).to eq("interactive")
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
