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
      it "resolves :fresh, :inherit, and :sibling_template to strategy instances" do
        expect(described_class.fetch(:fresh)).to be_a(described_class::Fresh)
        expect(described_class.fetch(:inherit)).to be_a(described_class::Inherit)
        expect(described_class.fetch(:sibling_template)).to be_a(described_class::SiblingTemplate)
      end

      it "accepts a String name" do
        expect(described_class.fetch("fresh")).to be_a(described_class::Fresh)
      end

      it "raises a loud, named error for an unknown strategy" do
        expect { described_class.fetch(:warm_handoff) }
          .to raise_error(described_class::Unknown, /warm_handoff/)
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

      it "shapes no child Context and journals no floor note (the uniform duck's no-op legs)" do
        context = Lain::Context.new(model: "child-model", max_tokens: 256)
        notes = []

        expect(strategy.child_context(context)).to be(context)
        strategy.journal_floor(notes)
        expect(notes).to be_empty
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

      it "shapes no child Context and journals no floor note (the uniform duck's no-op legs)" do
        context = Lain::Context.new(model: "child-model", max_tokens: 256)
        notes = []

        expect(strategy.child_context(context)).to be(context)
        strategy.journal_floor(notes)
        expect(notes).to be_empty
      end
    end

    describe described_class::SiblingTemplate do
      subject(:strategy) { described_class.new(template:) }

      let(:template) { "Shared sibling bulk: the same guidance for every worker." }
      let(:factory_context) do
        Lain::Context.new(model: "child-model", max_tokens: 256, system: "be small",
                          stream: false, extra: { "temperature" => 0 })
      end

      # Isolation is half the arm's pitch (CE-4: isolation AND amortized
      # bootstrap): like Fresh, the child starts from a new empty root over the
      # shared Store, so meet(child, parent) stays bottom.
      it "bases the child on an empty Timeline over the shared Store, like fresh" do
        base = strategy.base_timeline(parent:, store:)
        expect(base).to be_empty
        expect(base.store).to be(store)
        expect(base.meet(parent)).to be_empty
      end

      it "copies nothing into the Store" do
        parent # force the parent chain to build before measuring
        expect { strategy.base_timeline(parent:, store:) }.not_to(change { store.size })
      end

      it "labels itself sibling_template" do
        expect(strategy.label).to eq("sibling_template")
      end

      describe "#child_context (the template threading surface)" do
        it "appends the template as the LAST system block, preserving the factory context's own system ahead of it" do
          shaped = strategy.child_context(factory_context)

          expect(shaped.system).to eq(
            [{ "type" => "text", "text" => "be small" }, { "type" => "text", "text" => template }]
          )
        end

        it "carries the factory context's model, max_tokens, stream, and extra through unchanged" do
          shaped = strategy.child_context(factory_context)

          expect(shaped.model).to eq("child-model")
          expect(shaped.max_tokens).to eq(256)
          expect(shaped.stream).to be(false)
          expect(shaped.extra).to eq("temperature" => 0)
        end

        it "renders the template as the sole system block when the factory context has none" do
          bare = Lain::Context.new(model: "child-model", max_tokens: 256)
          expect(strategy.child_context(bare).system).to eq([{ "type" => "text", "text" => template }])
        end

        # The T24 trap, pinned at the source: Context#cache_marked marks the
        # final system block UNCONDITIONALLY, so a strategy that pre-marked the
        # template would put TWO marks in system -- and CacheBreakpoints budgets
        # its message markers assuming system spends exactly one slot, so the
        # extra mark can reach 5 on the wire (Anthropic 400s at >4). Leaving
        # every block unmarked makes Context's own mark the template boundary.
        it "pre-marks nothing: every block it builds is markerless" do
          expect(strategy.child_context(factory_context).system).to all(satisfy { |b| !b.key?("cache") })
        end

        it "passes the factory context through untouched when the template is empty" do
          bare = described_class.new
          expect(bare.child_context(factory_context)).to be(factory_context)
        end

        # A pre-marked factory system (the role_spec probe shape) is stripped,
        # not kept: the template demotes the marked block to non-last, so a
        # surviving caller mark would sit BESIDE Context's tail mark -- two
        # system marks, five on the wire at CacheBreakpoints' full budget.
        # The strategy owns all mark placement for the child, and says so.
        it "strips a caller-placed mark so exactly Context's tail mark reaches the wire, and journals the strip" do
          marked = Lain::Context.new(
            model: "child-model", max_tokens: 256,
            system: [{ "type" => "text", "text" => "bulk", "cache" => true }]
          )
          notes = []
          shaped = strategy.child_context(marked, journal: notes)

          expect(shaped.system).to eq(
            [{ "type" => "text", "text" => "bulk" }, { "type" => "text", "text" => template }]
          )
          expect(notes.map { |n| n.to_journal["type"] }).to eq(%w[system_mark_stripped])
          expect(notes.first.to_journal["stripped"]).to eq(1)
        end

        it "journals no strip note when the factory system carries no marks" do
          notes = []
          strategy.child_context(factory_context, journal: notes)

          expect(notes).to be_empty
        end
      end

      describe "#journal_floor (the minimum-cacheable-prefix note)" do
        it "journals a template_below_floor note when the template sits under the floor" do
          notes = []
          strategy.journal_floor(notes)

          expect(notes.size).to eq(1)
          record = notes.first.to_journal
          expect(record["type"]).to eq("template_below_floor")
          expect(record["strategy"]).to eq("sibling_template")
          expect(record["estimated_tokens"]).to be < record["floor"]
          expect(record["floor"]).to eq(described_class::MINIMUM_CACHEABLE_TOKENS)
        end

        it "journals nothing when the template clears the floor" do
          notes = []
          big = described_class.new(template: "x" * (described_class::MINIMUM_CACHEABLE_TOKENS *
                                                     described_class::CHARS_PER_TOKEN))
          big.journal_floor(notes)

          expect(notes).to be_empty
        end

        # fetch(:sibling_template) yields a template-less instance; using it is
        # legal but trivially under the floor, so the note fires -- the arm is
        # never SILENTLY un-cacheable.
        it "notes the floor for a bare fetch'd (template-less) instance" do
          notes = []
          Lain::Tool::SpawnPolicy::PrefixStrategy.fetch(:sibling_template).journal_floor(notes)

          expect(notes.map { |n| n.to_journal["type"] }).to eq(%w[template_below_floor])
        end
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
