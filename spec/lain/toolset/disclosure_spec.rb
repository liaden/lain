# frozen_string_literal: true

RSpec.describe Lain::Toolset::Disclosure do
  # Builds a throwaway tool class with a given name -- mirrors
  # spec/lain/toolset_spec.rb's helper, since this spec re-proves an invariant
  # about the SAME #to_schema output.
  def tool(tool_name)
    Class.new(Lain::Tool) do
      define_method(:name) { tool_name.to_s }
      define_method(:description) { "the #{tool_name} tool" }
      def perform(_input, _context) = Lain::Tool::Result.ok("ok")
    end.new
  end

  let(:read) { tool(:read_file) }
  let(:grep) { tool(:grep) }
  let(:bash) { tool(:bash) }
  let(:toolset) { Lain::Toolset.new([bash, grep, read]) }

  describe Lain::Toolset::Disclosure::Upfront do
    it "is byte-identical to today's Toolset#to_schema output" do
      rendered = described_class.new.render(toolset)

      expect(Lain::Canonical.dump(rendered)).to eq(Lain::Canonical.dump(toolset.to_schema))
    end

    it "is byte-identical regardless of construction order (cache stability)" do
      reordered = Lain::Toolset.new([read, grep, bash])

      expect(Lain::Canonical.dump(described_class.new.render(toolset)))
        .to eq(Lain::Canonical.dump(described_class.new.render(reordered)))
    end

    it "is byte-identical to #to_schema under attenuation, not just for the full set" do
      attenuated = toolset.only(:read_file, :grep).except(:grep)

      expect(Lain::Canonical.dump(described_class.new.render(attenuated)))
        .to eq(Lain::Canonical.dump(attenuated.to_schema))
    end
  end

  describe "as a pluggable seam" do
    # A second arm, defined entirely in this spec -- Toolset::Disclosure's
    # only obligation is #render(toolset). Toolset itself never names this
    # class, which is what "toolset.rb does not know the arm" means: the seam
    # is proven by a subclass this production code has never heard of.
    let(:alternate_arm) do
      Class.new(Lain::Toolset::Disclosure) do
        def render(_toolset)
          "deferred stand-in"
        end
      end
    end

    it "routes rendering through whatever strategy is given" do
      expect(alternate_arm.new.render(toolset)).to eq("deferred stand-in")
    end

    it "differs from the Upfront arm's output for the same toolset" do
      expect(alternate_arm.new.render(toolset)).not_to eq(Lain::Toolset::Disclosure::Upfront.new.render(toolset))
    end

    it "the base class refuses to render on its own -- an arm must be chosen" do
      expect { described_class.new.render(toolset) }
        .to raise_error(Lain::Toolset::Disclosure::NotImplemented, /must define #render/)
    end
  end
end
