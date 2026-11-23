# frozen_string_literal: true

RSpec.describe Lain::Agent::BeforeEffect do
  let(:tool) { Lain::Tools::Bash.new }

  it "calls each hook in order with the tool and the context" do
    seen = []
    first = ->(tool:, context:) { seen << [:first, tool.name, context] }
    second = ->(tool:, context:) { seen << [:second, tool.name, context] }

    described_class.new([first, second]).call(tool:, context: :ctx)

    expect(seen).to eq([[:first, "bash", :ctx], [:second, "bash", :ctx]])
  end

  it "lets a raising hook fail the call and stops the hooks after it" do
    later = []
    raising = ->(**) { raise "sync failed" }
    after = ->(tool:, **) { later << tool.name }

    expect { described_class.new([raising, after]).call(tool:, context: nil) }.to raise_error("sync failed")
    expect(later).to be_empty
  end

  it "does nothing as NONE" do
    expect(described_class::NONE.call(tool:, context: nil)).to be_nil
  end

  it "adds a hook with #with and leaves the original alone" do
    seen = []
    extended = described_class::NONE.with(->(tool:, **) { seen << tool.name })

    extended.call(tool:, context: nil)
    described_class::NONE.call(tool:, context: nil)

    expect(seen).to eq(["bash"])
  end

  describe "in a child agent" do
    let(:recorded) { [] }
    let(:hook) { ->(tool:, **) { recorded << tool.name } }
    let(:probes) do
      Lain::Role::Catalog[:dev].only.map do |name|
        Class.new(Lain::Tool) do
          define_method(:name) { name.to_s }
          def description = "writes"
          def input_schema = { type: :object, properties: {} }

          protected

          def perform(_input, _context) = Lain::Tool::Result.ok("ran")
        end.new
      end
    end

    it "carries the hooks the seam holds into the child's tool runs" do
      seam = Lain::Tools::Subagent::Seam.new(
        provider: Lain::Provider::Mock.new(responses: [tool_response(["c1", "bash", {}]), text_response("done")]),
        context_factory: -> { Lain::Context.new(model: "child", max_tokens: 256) },
        parent: Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store),
        tool_middleware: ToolRegistry::UNGUARDED,
        before_effect: described_class.new([hook])
      )
      spawner = Lain::Tools::Subagent.new(seam:, toolset: Lain::Toolset.new(probes),
                                          policy: Lain::Role::Catalog[:dev].spawn_policy(posture: :schema),
                                          budget: Lain::Budget.ceilings)

      spawner.call({ "prompt" => "go" }, Lain::Tool::Invocation.new(context: Lain::Session::Null.instance))

      expect(recorded).to eq(["bash"])
    end
  end
end
