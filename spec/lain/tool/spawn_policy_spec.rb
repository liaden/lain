# frozen_string_literal: true

RSpec.describe Lain::Tool::SpawnPolicy do
  # A two-turn parent chain over a shared Store; H is its head.
  let(:store) { Lain::Store.new }
  let(:parent) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                  .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
  end
  let(:union) { Lain::Toolset.new([EchoTool.new, BoomTool.new]) }
  let(:allowed) { union.only(:echo) }

  describe Lain::Tool::SpawnPolicy::PrefixStrategy do
    describe ".fetch" do
      it "resolves :fresh and :inherit to strategy instances" do
        expect(described_class.fetch(:fresh)).to be_a(described_class::Fresh)
        expect(described_class.fetch(:inherit)).to be_a(described_class::Inherit)
      end

      it "accepts a String name" do
        expect(described_class.fetch("fresh")).to be_a(described_class::Fresh)
      end

      it "raises a loud, named error for an unknown strategy" do
        expect { described_class.fetch(:sibling_template) }
          .to raise_error(described_class::Unknown, /sibling_template/)
      end
    end

    describe described_class::Fresh do
      subject(:strategy) { described_class.new }

      # A fresh root shares no history with the parent: it is a new root over the
      # SAME Store, so meet(child, parent) is the empty (bottom) Timeline.
      it "bases the child on an empty Timeline over the shared Store" do
        base = strategy.base_timeline(parent:, store:)
        expect(base).to be_empty
        expect(base.store).to be(store)
        expect(base.meet(parent)).to be_empty
      end

      it "copies nothing into the Store (an empty base commits no turn)" do
        parent # force the parent chain to build before measuring
        expect { strategy.base_timeline(parent:, store:) }.not_to(change { store.size })
      end

      it "labels itself fresh" do
        expect(strategy.label).to eq("fresh")
      end
    end

    describe described_class::Inherit do
      subject(:strategy) { described_class.new }

      # inherit == parent.fork: the child's head IS the parent's head before its
      # first commit, and forking is O(1) -- it copies nothing.
      it "bases the child on the parent's own head" do
        base = strategy.base_timeline(parent:, store:)
        expect(base.head_digest).to eq(parent.head_digest)
      end

      it "copies nothing into the Store (fork is identity)" do
        parent # force the parent chain to build before measuring
        expect { strategy.base_timeline(parent:, store:) }.not_to(change { store.size })
      end

      it "labels itself inherit" do
        expect(strategy.label).to eq("inherit")
      end
    end
  end

  describe Lain::Tool::SpawnPolicy::AttenuationPosture do
    describe ".fetch" do
      it "resolves :schema and :handler_union to posture instances" do
        expect(described_class.fetch(:schema)).to be_a(described_class::Schema)
        expect(described_class.fetch(:handler_union)).to be_a(described_class::HandlerUnion)
      end

      it "raises a loud, named error for an unknown posture" do
        expect { described_class.fetch(:banana) }
          .to raise_error(described_class::Unknown, /banana/)
      end
    end

    describe described_class::Schema do
      subject(:posture) { described_class.new }

      # schema attenuation: the model sees ONLY the allowed tools' schemas.
      it "renders the attenuated toolset and does not refuse over a union" do
        expect(posture.rendered_toolset(union:, allowed:)).to be(allowed)
        expect(posture.refuses_over_union?).to be(false)
      end

      it "labels itself schema" do
        expect(posture.label).to eq("schema")
      end
    end

    describe described_class::HandlerUnion do
      subject(:posture) { described_class.new }

      # handler_union: the model sees the SHARED UNION's schema (sibling spawns
      # render byte-identical tools blocks -- the CE-4 win; the union need not
      # equal the spawning parent's own toolset), and the Handler is what
      # enforces the attenuation.
      it "renders the shared union and refuses disallowed calls in the Handler" do
        expect(posture.rendered_toolset(union:, allowed:)).to be(union)
        expect(posture.refuses_over_union?).to be(true)
      end

      it "labels itself handler_union" do
        expect(posture.label).to eq("handler_union")
      end
    end
  end

  describe "the policy value grouping the two axes" do
    it "carries a prefix strategy, an attenuation posture, and the only-set" do
      policy = described_class.new(prefix: :inherit, posture: :handler_union, only: %i[echo])

      expect(policy.prefix).to be_a(Lain::Tool::SpawnPolicy::PrefixStrategy::Inherit)
      expect(policy.posture).to be_a(Lain::Tool::SpawnPolicy::AttenuationPosture::HandlerUnion)
      expect(policy.only).to eq(%w[echo])
    end

    it "defaults to fresh + schema (the schema posture is the default arm)" do
      policy = described_class.new(only: %i[echo])

      expect(policy.prefix).to be_a(Lain::Tool::SpawnPolicy::PrefixStrategy::Fresh)
      expect(policy.posture).to be_a(Lain::Tool::SpawnPolicy::AttenuationPosture::Schema)
    end

    it "attenuates a union down to the only-set, and to the full set when only is empty" do
      expect(described_class.new(only: %i[echo]).attenuate(union).names).to eq(%w[echo])
      expect(described_class.new(only: []).attenuate(union).names).to eq(union.names)
    end
  end
end
