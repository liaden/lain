# frozen_string_literal: true

RSpec.describe Lain::Mode::Resolution do
  # A REAL Toolset rather than a double, for the reason posture_spec records: a
  # verifying double's `#only` accepts any argument list at all, so a posture
  # naming a tool no live set holds would satisfy every example here and raise
  # at session start instead.
  let(:base) { Lain::Toolset.new(ToolRegistry.names.map { |name| ToolRegistry.build(name) }) }

  # Deliberately unstubbed. "Approves without consulting the queue" is an
  # assertion about a call that must NOT happen, and an unstubbed verifying
  # double raises the moment one does -- which is a stronger claim than a spy's
  # `not_to have_received`, because it also covers any other message.
  let(:queue) { instance_double(Lain::Approval::Queue) }

  let(:effect) { instance_double(Lain::Effect::ToolCall) }
  let(:context) { instance_double(Lain::Context) }

  def resolve(posture) = described_class.for(mode: Lain::Mode.new(posture:), base:, queue:)

  describe "plan, which attenuates rather than gates" do
    it "drops the mutating tools from the resolved toolset" do
      expect(resolve(:plan).toolset.names).not_to include("edit_file", "write_file", "bash")
    end

    it "keeps the tools a plan is made of" do
      expect(resolve(:plan).toolset.names).to include("read_file", "grep")
    end

    it "denies at the gate too, so nothing survives by a second route" do
      expect(resolve(:plan).gate_policy.call(effect, context)).to be(false)
    end
  end

  describe "auto" do
    it "approves without consulting the queue" do
      expect(resolve(:auto).gate_policy.call(effect, context)).to be(true)
    end

    it "holds every tool the session was built with" do
      expect(resolve(:auto).toolset).to be(base)
    end
  end

  describe "the postures that ask" do
    %i[manual accept_edits].each do |posture|
      it "#{posture} resolves its gate policy to the approval queue itself" do
        expect(resolve(posture).gate_policy).to be(queue)
      end
    end

    # No Null Object default stands behind `queue:`, and this is what says so:
    # an asking rung resolved without one would silently become plan's gate,
    # which is the same class, and the arm would deny every tier-3 call while
    # journalling itself as `manual`.
    it "refuses to resolve at all when no queue was named" do
      expect { described_class.for(mode: Lain::Mode.new(posture: :manual), base:) }
        .to raise_error(ArgumentError, /queue/)
    end
  end

  describe "the snapshot scope" do
    { plan: :write_set, manual: :write_set,
      accept_edits: :shadow_git, auto: :shadow_git }.each do |posture, scope|
      it "#{posture} selects #{scope}" do
        expect(resolve(posture).snapshot_scope).to eq(scope)
      end
    end

    it "stays an inert Symbol, so resolving needs no filesystem" do
      expect(resolve(:auto).snapshot_scope).to be_a(Symbol)
    end
  end

  describe "a posture naming a tool the base toolset lacks" do
    let(:phantom) do
      Lain::Mode::Posture.new(
        name: :phantom, permits: Lain::Mode::Posture::Permits::Only.new(%i[read_file no_such_tool]),
        gate_policy: :deny_all, snapshot_scope: :write_set, lighter: "PH"
      )
    end

    it "raises Toolset::UnknownTool, at the honest place" do
      expect { described_class.for(mode: Lain::Mode.new(posture: phantom), base:, queue:) }
        .to raise_error(Lain::Toolset::UnknownTool)
    end

    it "names the tool that is missing" do
      expect { described_class.for(mode: Lain::Mode.new(posture: phantom), base:, queue:) }
        .to raise_error(/no_such_tool/)
    end
  end

  describe "an undeclared gate policy" do
    let(:phantom) do
      Lain::Mode::Posture.new(name: :phantom, permits: Lain::Mode::Posture::Permits::All,
                              gate_policy: :turbo, snapshot_scope: :write_set, lighter: "PH")
    end

    it "fails loudly, listing the policies that are declared" do
      expect { described_class.for(mode: Lain::Mode.new(posture: phantom), base:, queue:) }
        .to raise_error(described_class::Unknown, /turbo.*deny_all.*queue.*approve_all/m)
    end
  end

  # The escalation trigger this card carries: attenuation is monotone, so a
  # resolution may never re-grant on an already-attenuated set. Resolving is a
  # pure function of the mode and the BASE, which is what makes leaving plan an
  # ordinary resolution rather than a widening.
  describe "monotonicity" do
    it "rebuilds from the base rather than from whatever the last posture left" do
      resolve(:plan)
      expect(resolve(:auto).toolset).to eq(base)
    end

    it "hands the base straight back under a posture that attenuates nothing" do
      expect(resolve(:manual).toolset).to be(base)
    end
  end

  describe "the resolution itself" do
    it "is a frozen value" do
      expect(resolve(:manual)).to be_frozen
    end

    it "answers the three things a posture declared, and nothing else" do
      expect(resolve(:auto).to_h.keys).to eq(%i[toolset gate_policy snapshot_scope])
    end
  end
end
