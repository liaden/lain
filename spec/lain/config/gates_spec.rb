# frozen_string_literal: true

require "tmpdir"

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
  end
end
