# frozen_string_literal: true

require "tmpdir"

# The collaborator the panel asked to be extracted: Config locates the
# file and dispatches to it, but validating [epics]'s own shape is this
# class's job, exercised directly rather than only ever through Config.load.
RSpec.describe Lain::Config::Epics do
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

# A second describe, because these examples reach `[epics]` the way a project
# does -- through Config.load, so `described_class` has to be Lain::Config.
# That path is also the only one that can name the config file in a refusal.
RSpec.describe Lain::Config do
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
end
