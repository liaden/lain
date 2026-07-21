# frozen_string_literal: true

# LockedBinding hands whatever its resolver returns straight to ERB.new. A
# String is the only shape ERB accepts; anything else -- an Integer digest, a
# byte count -- crashed opaquely inside ERB, naming neither the slot nor the
# value. Pins the loud replacement: a named Prompt::NonStringSlot, naming both.
RSpec.describe Lain::Prompt::LockedBinding do
  describe "#render (the resolver -> evaluate path)" do
    it "raises Prompt::NonStringSlot naming the slot and the value's class when the resolver returns an Integer" do
      engine = described_class.new(resolve: ->(_name) { 5 })

      expect { engine.render("age_turns") }
        .to raise_error(Lain::Prompt::NonStringSlot) { |e|
          expect(e.message).to include("age_turns")
          expect(e.message).to include("Integer")
        }
    end

    it "still renders a genuine String slot value (the loud check does not touch the happy path)" do
      engine = described_class.new(resolve: ->(_name) { "old tool output" })

      expect(engine.render("content")).to eq("old tool output")
    end
  end

  describe "#render_template (the same evaluate path, for the top-level source)" do
    it "raises Prompt::NonStringSlot naming the label and the value's class for a non-String source" do
      engine = described_class.new(resolve: ->(name) { name })

      expect { engine.render_template(5, "byte_count") }
        .to raise_error(Lain::Prompt::NonStringSlot) { |e|
          expect(e.message).to include("byte_count")
          expect(e.message).to include("Integer")
        }
    end
  end
end
