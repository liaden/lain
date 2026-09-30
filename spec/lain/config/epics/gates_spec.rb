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
      .to raise_error(Lain::Config::Refusal, /reserch/)
  end

  it "refuses an unknown policy at construction, not just through .from" do
    expect { described_class.new(table: { "research" => "yolo" }) }
      .to raise_error(Lain::Config::Refusal, /yolo/)
  end

  it "refuses a non-table at construction" do
    expect { described_class.new(table: "deferred") }
      .to raise_error(Lain::Config::Refusal, /`gate` must be a table/)
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
        .to raise_error(Lain::Config::Refusal,
                        "`gate` has no stages \"reserch\"; " \
                        "the pipeline is research -> epic_plan -> issue_plan -> implementation")
    end

    # Likewise: widening {Approval::Gate::Policies} must update the list below,
    # and the red you are reading is this pin doing its job, not a broken factory.
    it "names the unknown policies and every policy the factory does build" do
      expect { described_class.new(table: { "research" => "yolo" }) }
        .to raise_error(Lain::Config::Refusal,
                        "`gate` names unknown gate policies \"yolo\"; " \
                        "known policies: interactive, hands_off, deferred, adjudicated")
    end

    it "names the type it got where the sub-table is not a table" do
      expect { described_class.new(table: "deferred") }
        .to raise_error(Lain::Config::Refusal,
                        "`gate` must be a table, got String: \"deferred\"")
    end
  end

  # `Epic::STAGES` and `Approval::Gate::Policies` are read inside METHOD BODIES,
  # at call time, and this pins them there. A class-body reference to either --
  # the shape a declarative closed-set validation naturally takes -- would make
  # reaching the config unit reach two unrelated units with it, which is what
  # this asks and refuses. EMPTY is the proof case: built while this file loads,
  # and surviving only because an empty table is answered before either set is
  # read.
  #
  # Asked of a child booted WITHOUT the eager load, because that is the only
  # boot in which the question has an answer: eager loading defines every
  # constant in lib/ whatever any one file references, so the reachability
  # claim is invisible from inside this process.
  #
  # And asked of $LOADED_FEATURES rather than of `const_defined?`, which
  # answers TRUE for a name the loader has merely registered an autoload for --
  # every constant in lib/, from `setup` onward. Whether the file RAN is the
  # only form of the question autoloading leaves standing.
  describe "what reaching it pulls in" do
    def lazy_boot_script
      root = File.expand_path("../../../..", __dir__)
      entry = File.join(root, "lib", "lain.rb")
      <<~RUBY
        source = File.readlines(#{entry.inspect}).reject { |line| line.start_with?("loader.eager_load") }.join
        eval(source, TOPLEVEL_BINDING, #{entry.inspect})
      RUBY
    end

    it "reaches the whole config unit without loading the epic or approval units" do
      script = "#{lazy_boot_script}\n" \
               "loaded = ->(unit) { $LOADED_FEATURES.any? { |path| path.end_with?(\"/lain/\#{unit}.rb\") } }\n" \
               "print [Lain::Config.empty.class.name, loaded.call(\"epic\"), loaded.call(\"approval\")].inspect"

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
  # same unknown-key posture the parent table already carries.
  describe "[epics.gates]" do
    it "reads a policy per stage" do
      Dir.mktmpdir do |root|
        write_config(root, <<~RUBY)
          epics do
            gate :research, :hands_off
            gate :epic_plan, :deferred
          end
        RUBY

        config = described_class.load(root:)

        expect(config.gate_policy_for("research")).to eq("hands_off")
        expect(config.gate_policy_for("epic_plan")).to eq("deferred")
      end
    end

    it "leaves a stage the table does not name interactive" do
      Dir.mktmpdir do |root|
        write_config(root, "epics gates: { research: :hands_off }\n")

        expect(described_class.load(root:).gate_policy_for("issue_plan")).to eq("interactive")
      end
    end

    it "is interactive everywhere when the table is absent" do
      Dir.mktmpdir do |root|
        write_config(root, "epics home: :repo\n")

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
        write_config(root, <<~RUBY)
          epics home: :repo do
            gate :research, :hands_off
          end
        RUBY

        config = described_class.load(root:)

        expect(config.epics_home).to eq(:repo)
        expect(config.gate_policy_for("research")).to eq("hands_off")
      end
    end

    it "refuses a typo in a stage name, naming the unknown key" do
      Dir.mktmpdir do |root|
        write_config(root, "epics gates: { reserch: :deferred }\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Refusal, /reserch/)
      end
    end

    it "names the pipeline it expected, so the typo is fixable from the message" do
      Dir.mktmpdir do |root|
        write_config(root, "epics gates: { reserch: :deferred }\n")

        expect { described_class.load(root:) }.to raise_error(/research/)
      end
    end

    it "names every unknown stage in one pass, not just the first" do
      Dir.mktmpdir do |root|
        write_config(root, "epics gates: { zzz: :deferred, aaa: :deferred }\n")

        expect { described_class.load(root:) }.to raise_error do |error|
          expect(error.key).to contain_exactly("zzz", "aaa")
        end
      end
    end

    it "refuses an unknown policy name, naming it and the known policies" do
      Dir.mktmpdir do |root|
        write_config(root, "epics gates: { research: :yolo }\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Refusal, /yolo/) do |error|
            expect(error.message).to include("hands_off")
            expect(error.message).to include("deferred")
          end
      end
    end

    it "refuses a wrong-typed policy value the same way it refuses a bad string" do
      Dir.mktmpdir do |root|
        write_config(root, "epics gates: { research: 3 }\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Refusal, /names unknown gate policies 3/)
      end
    end

    it "refuses a gates value that is not a table" do
      Dir.mktmpdir do |root|
        write_config(root, "epics gates: \"deferred\"\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Refusal, /must be a table/)
      end
    end

    it "carries the path and the offending keys on a gates refusal" do
      Dir.mktmpdir do |root|
        write_config(root, "epics gates: { reserch: :deferred }\n")

        expect { described_class.load(root:) }.to raise_error do |error|
          expect(error.path).to eq("#{config_path(root)}:1")
          expect(error.key).to eq(["reserch"])
        end
      end
    end

    # Spells out {Epic::STAGES} for the reason the hand-built pin above does, and
    # carries the same debt: a new stage updates both, or both go red together.
    it "names the file, the unknown stages, and the pipeline" do
      Dir.mktmpdir do |root|
        write_config(root, "epics gates: { reserch: :deferred }\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Refusal,
                          "#{config_path(root)}:1: `gate` has no stages \"reserch\"; " \
                          "the pipeline is research -> epic_plan -> issue_plan -> implementation")
      end
    end

    # Stated as a RELATION between the two refusals rather than as two literals,
    # because what has to hold is that they cannot DRIFT: {Gates#initialize}
    # re-runs the same closed-set check `.from` does, so the only difference a
    # hand-built value is entitled to is the config path it has no way to know.
    it "refuses a hand-built value as it refuses a loaded one, minus the path prefix" do
      Dir.mktmpdir do |root|
        write_config(root, "epics gates: { reserch: :deferred }\n")

        loaded = refusal_from { described_class.load(root:) }
        hand_built = refusal_from { Lain::Config::Epics::Gates.new(table: { "reserch" => "deferred" }) }

        expect([loaded.class, loaded.message])
          .to eq([hand_built.class, "#{config_path(root)}:1: #{hand_built.message}"])
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
