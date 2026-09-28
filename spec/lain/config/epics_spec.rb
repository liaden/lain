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
      .to raise_error(Lain::Config::Refusal, /yolo/)
  end

  it "refuses a hand-built gates table keyed on a stage that does not exist" do
    expect { described_class.new(home: :xdg, gates: { "reserch" => "deferred" }) }
      .to raise_error(Lain::Config::Refusal, /reserch/)
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
      .to raise_error(Lain::Config::Refusal, /\[epics\.gates\] must be a table/)
  end

  # Data#with re-runs #initialize, so the guard has to hold on the copy too.
  it "re-checks gates through #with" do
    expect { described_class.new(home: :xdg).with(gates: { "research" => "yolo" }) }
      .to raise_error(Lain::Config::Refusal, /unknown gate policies "yolo"/)
  end

  it "leaves Config#gate_policy_for total for any value that constructs" do
    config = Lain::Config.new(epics: described_class.new(home: :xdg, gates: { "research" => "hands_off" }))

    expect(config.gate_policy_for("implementation")).to eq("interactive")
  end

  # Panel review round 2: Epics.new bypasses .from entirely, so the closed
  # set has to be enforced in the value's own constructor too -- Epic::Issue
  # does exactly this, and this whole wave's blockers were all variants of
  # "constructs fine, fails later" (a downstream consumer is specified to `case`
  # on epics_home, so a value that skipped this check would reach it live).
  it "refuses a value outside the closed set at construction, not just through .from" do
    expect { described_class.new(home: :bogus) }.to raise_error(Lain::Config::Refusal, /bogus/)
  end

  # A width absent from the table is not a zero: it means the project said
  # nothing, and the driver derives its own from where the models run.
  it "leaves width unsaid for an empty table" do
    expect(described_class.from({}, path: "/irrelevant").width).to be_nil
  end

  it "reads a width the table declares" do
    expect(described_class.from({ "width" => 4 }, path: "/irrelevant").width).to eq(4)
  end

  # A width counts the issues carried at once, so everything outside the whole
  # numbers above zero means nothing -- and a zero in particular would drive an
  # epic that launches nothing while reporting nothing wrong.
  [0, -1, "two", 1.5, true].each do |literal|
    it "refuses a width of #{literal.inspect}" do
      expect { described_class.from({ "width" => literal }, path: "/irrelevant") }
        .to raise_error(Lain::Config::Refusal, /width .* is not a whole number of issues above zero/)
    end
  end

  # The guard belongs to the VALUE, as `home`'s and `gates`' do: a hand-built
  # width of zero must refuse here rather than three frames into a run.
  it "refuses a hand-built width outside the whole numbers above zero" do
    expect { described_class.new(home: :xdg, width: 0) }
      .to raise_error(Lain::Config::Refusal, "[epics] width 0 is not a whole number of issues above zero")
  end

  it "re-checks width through #with" do
    expect { described_class.new(home: :xdg).with(width: -2) }.to raise_error(Lain::Config::Refusal, /width/)
  end

  # Pinned literally, not by a regex that would survive a rewording. Each of
  # these messages is computed from the OFFENDING VALUE -- the symbol, the set
  # difference -- and not from the name of the attribute that carried it, so a
  # rewrite that reported only which attribute was at fault would still match
  # every /bogus/ above while telling a reader strictly less than this does.
  describe "the message a refusal carries" do
    it "names the offending home and both permitted values" do
      expect { described_class.new(home: :bogus) }
        .to raise_error(Lain::Config::Refusal, "epics_home :bogus is not one of xdg, repo")
    end

    it "renders a wrong-typed home as the value it was, not as its attribute" do
      expect { described_class.new(home: 3) }
        .to raise_error(Lain::Config::Refusal, "epics_home 3 is not one of xdg, repo")
    end
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
          .to raise_error(Lain::Config::Refusal, /hoem/)
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
          expect(error.key).to eq(["hoem"])
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
          expect(error.key).to contain_exactly("zzz", "aaa")
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

    # `width`'s own near miss. An unknown key is refused rather than ignored,
    # so a project that meant to slow a run down learns that it did not, rather
    # than watching the old width and wondering.
    it "refuses widht, naming it and the keys it does know" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics]\nwidht = 2\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Refusal, /widht.*known keys: home, gates, width/)
      end
    end

    # Panel probe: `[epics.sub]` parses to a nested Hash under the "sub" key --
    # still an unrecognized key, not a different code path.
    it "refuses a nested [epics.sub] table as an unknown key" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics.sub]\nk = 1\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Refusal, /sub/)
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

  describe "[epics] width" do
    it "reads the width a project declares" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics]\nwidth = 4\n")

        expect(described_class.load(root:).epics.width).to eq(4)
      end
    end

    it "names the file and the offending width" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics]\nwidth = 0\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Refusal,
                          "#{config_path(root)}: [epics] width 0 is not a whole number of issues above zero")
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
          .to raise_error(Lain::Config::Refusal, /somewhere_else/) do |error|
            expect(error.message).to include("xdg")
            expect(error.message).to include("repo")
          end
      end
    end

    it "refuses an empty string, naming both allowed values" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics]\nhome = \"\"\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Refusal, /epics_home "" is not one of xdg, repo/)
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
            .to raise_error(Lain::Config::Refusal) do |error|
              expect(error.message).to include("xdg")
              expect(error.message).to include("repo")
            end
        end
      end
    end

    it "refuses an array the same way it refuses a bad string" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics]\nhome = [\"repo\"]\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Refusal, /epics_home \["repo"\] is not one of/)
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

  # The loaded path's messages, pinned literally for the reason the hand-built
  # ones are, plus one this path alone can state: the file to open comes FIRST,
  # so a refusal read out of a CI log is actionable without a second run.
  describe "the message a loaded refusal carries" do
    it "names the file, the unknown keys, and the keys it does know" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics]\nhoem = \"repo\"\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Refusal,
                          "#{config_path(root)}: [epics] has no keys \"hoem\"; known keys: home, gates, width")
      end
    end

    it "names the file, the offending home, and both permitted values" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics]\nhome = \"somewhere_else\"\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Refusal,
                          "#{config_path(root)}: epics_home \"somewhere_else\" is not one of xdg, repo")
      end
    end

    it "names the file and the type it got where [epics] is not a table at all" do
      Dir.mktmpdir do |root|
        write_config(root, "epics = \"x\"\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Refusal,
                          "#{config_path(root)}: [epics] must be a table, got String: \"x\"")
      end
    end
  end
end
