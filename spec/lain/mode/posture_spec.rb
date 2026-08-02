# frozen_string_literal: true

RSpec.describe Lain::Mode::Posture do
  let(:all_postures) { described_class::NAMES.map { |name| described_class.for(name) } }

  describe "the closed set" do
    it "names exactly the four rungs of the ladder" do
      expect(described_class::NAMES).to eq(%i[plan manual accept_edits auto])
    end

    it "hands back the posture asked for" do
      expect(all_postures.map(&:name)).to eq(described_class::NAMES)
    end

    it "accepts a String name, because a CLI argument arrives as one" do
      expect(described_class.for("plan")).to eq(described_class.for(:plan))
    end

    it "hands back the same value every time, so a posture is a constant not a build" do
      expect(described_class.for(:auto)).to be(described_class.for(:auto))
    end
  end

  describe "an unknown posture" do
    it "raises ArgumentError" do
      expect { described_class.for(:turbo) }.to raise_error(ArgumentError)
    end

    it "names the posture asked for" do
      expect { described_class.for(:turbo) }.to raise_error(/turbo/)
    end

    it "lists every valid alternative" do
      expect { described_class.for(:turbo) }.to raise_error(/plan.*manual.*accept_edits.*auto/m)
    end
  end

  describe "plan's capability set" do
    let(:permits) { described_class.for(:plan).permits }

    %i[edit_file write_file memory_write bash core_exec].each do |tool|
      it "does not permit #{tool}" do
        expect(permits).not_to include(tool)
      end
    end

    it "does not permit run_skill, which reaches whatever tools the skill names" do
      expect(permits).not_to include(:run_skill)
    end

    it "still permits reading" do
      expect(permits).to include(:read_file)
    end

    it "still permits searching, so a plan can be grounded" do
      expect(permits).to include(:grep, :glob, :list_files)
    end

    it "answers to a tool name given as a String too" do
      expect(permits).to include("read_file")
    end
  end

  describe "the postures that attenuate nothing" do
    let(:toolset) { instance_double(Lain::Toolset) }

    %i[manual accept_edits auto].each do |name|
      it "#{name} permits every tool the session holds" do
        expect(described_class.for(name).permits).to include(:bash, :edit_file, :core_exec)
      end

      it "#{name} hands the toolset back untouched rather than rebuilding it" do
        expect(described_class.for(name).attenuate(toolset)).to be(toolset)
      end
    end
  end

  describe "#attenuate" do
    it "restricts the toolset down to plan's declared set" do
      attenuated = instance_double(Lain::Toolset)
      toolset = instance_double(Lain::Toolset, only: attenuated)
      expect(described_class.for(:plan).attenuate(toolset)).to be(attenuated)
    end

    it "asks for the same tools it reports permitting" do
      toolset = instance_double(Lain::Toolset, only: nil)
      described_class.for(:plan).attenuate(toolset)
      expect(toolset).to have_received(:only) do |*names|
        expect(names).to include(:read_file)
        expect(names).not_to include(:bash)
      end
    end
  end

  # The double-based examples above confirm that #attenuate CALLS #only. Nothing
  # there confirms that #only SURVIVES: a verifying double accepts any argument
  # list, so a posture naming a tool no real Toolset holds passes every one of
  # them and raises at session start. These go through real Toolsets for that
  # reason, and they are the ones that guard the availability direction --
  # a name here the live set lacks is a hard raise, not a quiet narrowing.
  describe "plan against a real Toolset" do
    let(:plan) { described_class.for(:plan) }
    let(:shipped) { Lain::Toolset.new(ToolRegistry.names.map { |name| ToolRegistry.build(name) }) }

    # `BaseTools.build` is the capability floor; `ToolsetBuild#build` appends the
    # reply seam on top of it, so `ask_human` is in the live chat set and in no
    # other assembly. A check built from the floor alone would miss it.
    let(:chat) do
      Lain::Toolset.new(Lain::CLI::Wiring::BaseTools.build(Lain::Memory::Recorder.new) +
                        [ToolRegistry.build("ask_human")])
    end

    it "names no tool the shipped registry lacks" do
      expect { plan.attenuate(shipped) }.not_to raise_error
    end

    it "names no tool the live chat toolset lacks" do
      expect { plan.attenuate(chat) }.not_to raise_error
    end

    it "drops every shipped tool that can change something" do
      expect(plan.attenuate(shipped).names)
        .not_to include("bash", "core_exec", "edit_file", "write_file", "memory_write",
                        "improvement_write", "todo_write", "run_skill", "subagent",
                        "request_review", "tool_search")
    end

    it "leaves a plan able to read, to search, and to ask" do
      expect(plan.attenuate(shipped).names).to include("read_file", "grep", "ask_human")
    end

    it "hands a real toolset straight back under a posture that attenuates nothing" do
      expect(described_class.for(:auto).attenuate(shipped)).to be(shipped)
    end
  end

  describe "the Permits duck" do
    let(:arms) { [described_class::Permits::All, described_class::Permits::Only.new([])] }

    it "is answered whole by both arms" do
      expect(arms).to all(respond_to(:attenuate, :include?))
    end

    it "is exactly those two: Only's Data accessors are not part of it" do
      expect(described_class::Permits::All).not_to respond_to(:names, :to_h, :deconstruct)
    end

    it "refuses a nil tool name on both arms, so the Null is not the lenient one" do
      expect(arms).to all(satisfy { |permits| raises_no_method?(permits) })
    end

    it "names itself when inspected, so a describe or a journal record reads" do
      expect(described_class::Permits::All.inspect).to eq("Lain::Mode::Posture::Permits::All")
    end

    def raises_no_method?(permits)
      permits.include?(nil)
      false
    rescue NoMethodError
      true
    end
  end

  describe "lighters" do
    it "leaves the default posture silent" do
      expect(described_class.for(:accept_edits).lighter).to be_empty
    end

    it "gives every other posture something to render" do
      loud = all_postures.reject { |posture| posture.name == :accept_edits }
      expect(loud.map(&:lighter)).to all(satisfy { |lighter| !lighter.empty? })
    end

    it "gives each loud posture a distinct lighter" do
      lighters = all_postures.map(&:lighter).reject(&:empty?)
      expect(lighters.uniq.size).to eq(lighters.size)
    end
  end

  describe "the declared ladder" do
    # The design table, pinned in one place, so a rung that silently changes its
    # gate or its snapshot scope fails HERE rather than three cards downstream
    # where the symbol has already become an object.
    {
      plan: { gate_policy: :deny_all, snapshot_scope: :write_set, lighter: "PLAN" },
      manual: { gate_policy: :queue, snapshot_scope: :write_set, lighter: "MAN" },
      accept_edits: { gate_policy: :queue, snapshot_scope: :shadow_git, lighter: "" },
      auto: { gate_policy: :approve_all, snapshot_scope: :shadow_git, lighter: "AUTO" }
    }.each do |name, declared|
      it "#{name} declares its gate policy, snapshot scope and lighter" do
        posture = described_class.for(name)
        expect(posture.to_h.slice(:gate_policy, :snapshot_scope, :lighter)).to eq(declared)
      end
    end
  end

  describe "immutability" do
    it "is a deeply frozen value, so a posture can cross a Ractor" do
      expect(all_postures).to all(satisfy { |posture| Ractor.shareable?(posture) })
    end

    it "freezes the name roster too" do
      expect(described_class::NAMES).to be_frozen
    end

    it "keeps the lookup table off the public surface" do
      expect { described_class::POSTURES }.to raise_error(NameError)
    end
  end
end
