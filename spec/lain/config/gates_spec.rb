# frozen_string_literal: true

require "tmpdir"
require "open3"

RSpec.describe Lain::Config::Epics::Gates do
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

  # Pinned literally rather than by a regex, because each message is computed
  # from the OFFENDING VALUE and then spells out the closed set the reader is
  # being measured against -- the typo AND its fix, in one line. A refusal that
  # named only the attribute at fault would still satisfy every /reserch/ above.
  describe "the message a refusal carries" do
    # If you got here by adding a STAGE, this pin is what you owe: widening
    # {Epic::STAGES} must update the pipeline spelled out below. It is written
    # out rather than derived from the constant on purpose -- deriving it would
    # assert only that the message interpolates something, which is the tautology
    # this example exists to avoid.
    it "names the unknown stages and the pipeline they were measured against" do
      expect { described_class.new(table: { "reserch" => "deferred" }) }
        .to raise_error(Lain::Config::Epics::Gates::UnknownStages,
                        "[epics.gates] has no stages \"reserch\"; " \
                        "the pipeline is research -> epic_plan -> issue_plan -> implementation")
    end

    # Likewise: widening {Approval::Gate::Policies} must update the list below,
    # and the red you are reading is this pin doing its job, not a broken factory.
    it "names the unknown policies and every policy the factory does build" do
      expect { described_class.new(table: { "research" => "yolo" }) }
        .to raise_error(Lain::Config::Epics::Gates::UnknownPolicies,
                        "[epics.gates] names unknown gate policies \"yolo\"; " \
                        "known policies: interactive, hands_off, deferred, adjudicated")
    end

    it "names the type it got where the sub-table is not a table" do
      expect { described_class.new(table: "deferred") }
        .to raise_error(Lain::Config::Epics::Gates::NotATable,
                        "[epics.gates] must be a table, got String: \"deferred\"")
    end
  end

  # `Epic::STAGES` and `Approval::Gate::Policies` are read inside METHOD BODIES,
  # at call time, and this pins them there. `lain.rb` loads config eight units in
  # and epic sixty further down, so a class-body reference to either -- the shape
  # a declarative closed-set validation naturally takes -- would resolve during
  # `require` and take the whole library down, not merely this file's specs.
  # EMPTY is the proof case: built while this file loads, and surviving only
  # because an empty table is answered before either set is read.
  describe "the load order it is declared under" do
    # The manifest is the authority on what precedes config, so the prefix is
    # read from it rather than restated here and left to rot.
    def manifest_prefix_through_config
      root = File.expand_path("../../..", __dir__)
      units = File.readlines(File.join(root, "lib", "lain.rb"))
                  .filter_map { |line| line[/^require_relative "(.+)"/, 1] }

      units[0..units.index("lain/config")].map { |unit| File.join(root, "lib", "#{unit}.rb") }
    end

    it "loads the whole config unit without defining Epic or Approval" do
      script = manifest_prefix_through_config.map { |file| "require #{file.inspect}" }.join("\n")
      script += "\nprint [Lain::Config.empty.class.name, Object.const_defined?(\"Lain::Epic\"), " \
                "Object.const_defined?(\"Lain::Approval\")].inspect"

      out, status = Open3.capture2e(RbConfig.ruby, "-e", script)

      expect([out, status.success?]).to eq(['["Lain::Config", false, false]', true])
    end
  end
end

# A second describe, because these examples reach `[epics.gates]` the way a
# project does -- through Config.load, so `described_class` has to be
# Lain::Config. That path is what threads the path every refusal names.
RSpec.describe Lain::Config do
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

    # Spells out {Epic::STAGES} for the reason the hand-built pin above does, and
    # carries the same debt: a new stage updates both, or both go red together.
    it "names the file, the unknown stages, and the pipeline" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics.gates]\nreserch = \"deferred\"\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Epics::Gates::UnknownStages,
                          "#{config_path(root)}: [epics.gates] has no stages \"reserch\"; " \
                          "the pipeline is research -> epic_plan -> issue_plan -> implementation")
      end
    end

    # Stated as a RELATION between the two refusals rather than as two literals,
    # because what has to hold is that they cannot DRIFT: {Gates#initialize}
    # re-runs the same closed-set check `.from` does, so the only difference a
    # hand-built value is entitled to is the config path it has no way to know.
    it "refuses a hand-built value as it refuses a loaded one, minus the path prefix" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics.gates]\nreserch = \"deferred\"\n")

        loaded = refusal_from { described_class.load(root:) }
        hand_built = refusal_from { Lain::Config::Epics::Gates.new(table: { "reserch" => "deferred" }) }

        expect([loaded.class, loaded.message])
          .to eq([hand_built.class, "#{config_path(root)}: #{hand_built.message}"])
      end
    end
  end

  # Captures a refusal so that two of them can be COMPARED. `raise_error` matches
  # one in place and cannot state a relation between the loaded and hand-built
  # forms, which is the whole point of the example that uses this.
  def refusal_from
    yield
    raise "expected a refusal, and nothing was raised"
  rescue Lain::Error => e
    e
  end
end
