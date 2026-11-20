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

  describe "declared locals" do
    def engine(locals) = described_class.new(resolve: ->(name) { "<%= #{name} %>" }, locals:)

    it "renders a declared local read" do
      expect(engine(epic_home: "/state/epics/abc").render_template("home=<%= epic_home %>", "t"))
        .to eq("home=/state/epics/abc")
    end

    it "hands the same locals to a rendered partial" do
      expect(engine(epic_home: "/state/epics/abc").render("epic_home")).to eq("/state/epics/abc")
    end

    it "freezes the value a callable local resolves to" do
      value = +"/lazy"
      engine(epic_home: -> { value }).render_template("<%= epic_home %>", "t")

      expect(value).to be_frozen
    end

    it "still refuses a name nobody declared, naming it" do
      expect { engine({}).render_template("<%= epic_home %>", "t") }
        .to raise_error(Lain::Prompt::ImpureSlot, /epic_home/)
    end

    it "still refuses a method call on a declared local" do
      expect { engine(epic_home: "/x").render_template("<%= epic_home.upcase %>", "t") }
        .to raise_error(Lain::Prompt::ImpureSlot, /upcase/)
    end
  end

  # A value is data, not a template: its bytes are spliced in after the one
  # ERB pass, so a transcript quoting a Rails view can never be compiled.
  describe "values" do
    def engine(values) = described_class.new(resolve: ->(name) { raise KeyError, name }, values:)

    it "renders a value holding a Rails helper tag byte for byte" do
      text = "The view has <%= link_to 'Back', posts_path %> at the bottom."

      expect(engine("held" => text).render_template(%(<%= render("held") %>), "t")).to eq(text)
    end

    it "never evaluates a pure ERB tag in a value" do
      rendered = engine("held" => %(literal <%= "INJECTED" %> text)).render_template(%(<%= render("held") %>), "t")

      expect(rendered).to eq(%(literal <%= "INJECTED" %> text))
    end

    it "keeps a value's bytes when a value names the next value's placeholder" do
      values = { "a" => "\u0000lain-fragment:1\u0000", "b" => "B" }

      expect(engine(values).render_template(%([<%= render("a") %>|<%= render("b") %>]), "t"))
        .to eq("[\u0000lain-fragment:1\u0000|B]")
    end

    it "splices a value a resolved partial renders" do
      binding = described_class.new(resolve: ->(_name) { %(<<%= render("held") %>>) }, values: { "held" => "<%= x %>" })

      expect(binding.render_template(%(<%= render("frame") %>), "t")).to eq("<<%= x %>>")
    end

    it "resolves a callable value only when a template renders it" do
      calls = 0
      counted = lambda do
        calls += 1
        "x"
      end
      engine("held" => counted).render_template("no reference", "t")

      expect(calls).to eq(0)
    end

    it "raises Prompt::NonStringSlot naming a value that is not a String" do
      expect { engine("age_turns" => 5).render_template(%(<%= render("age_turns") %>), "t") }
        .to raise_error(Lain::Prompt::NonStringSlot, /age_turns.*Integer/)
    end

    it "renders a template holding a bare NUL byte unchanged" do
      expect(engine({}).render_template("a\u0000b", "t")).to eq("a\u0000b")
    end

    # A template can build a placeholder at evaluation time from a string escape, which no
    # source scan sees, so the splice itself refuses any placeholder `render` did not emit.
    describe "a placeholder the template forged" do
      let(:values) { { "a" => "AAA", "b" => "BBB" } }

      it "refuses one that repeats a value" do
        template = %(<%= render("a") %>|<%= "\\0lain-fragment:0\\0" %>|<%= render("b") %>)

        expect { engine(values).render_template(template, "t") }.to raise_error(Lain::Prompt::ImpureSlot, /"t"/)
      end

      it "refuses one that moves a value ahead of its place" do
        template = %(<%= "\\x00lain-fragment:1\\x00" %>|<%= render("a") %>|<%= render("b") %>)

        expect { engine(values).render_template(template, "t") }.to raise_error(Lain::Prompt::ImpureSlot, /"t"/)
      end

      it "refuses every value present once but out of order" do
        template = %(<% render("a") %><% render("b") %><%= "\\0lain-fragment:1\\0" %>|<%= "\\0lain-fragment:0\\0" %>)

        expect { engine(values).render_template(template, "t") }.to raise_error(Lain::Prompt::ImpureSlot, /"t"/)
      end

      it "refuses one past the last value" do
        expect { engine(values).render_template(%(<%= "\\0lain-fragment:7\\0" %>), "t") }
          .to raise_error(Lain::Prompt::ImpureSlot, /"t"/)
      end
    end

    it "keeps the outer render's values when a callable value renders through the same binding" do
      shared = nil
      values = { "outer" => -> { shared.render_template(%(<%= render("y") %>), "in") }, "x" => "X", "y" => "Y" }
      shared = described_class.new(resolve: ->(name) { raise KeyError, name }, values:)

      expect(shared.render_template(%(<%= render("x") %>|<%= render("outer") %>), "t")).to eq("X|Y")
    end

    it "keeps the outer render's values when a callable value rescues a failed inner render" do
      shared = nil
      rescued = lambda do
        shared.render_template(%(<%= render("y") %><%= Time.now %>), "in")
      rescue Lain::Prompt::ImpureSlot
        "R"
      end
      shared = described_class.new(resolve: ->(name) { raise KeyError, name },
                                   values: { "outer" => rescued, "x" => "X", "y" => "Y" })

      expect(shared.render_template(%(<%= render("x") %>|<%= render("outer") %>|<%= render("x") %>), "t"))
        .to eq("X|R|X")
    end

    it "still checks the template that renders a value for purity" do
      expect { engine("held" => "x").render_template(%(<%= Time.now %><%= render("held") %>), "t") }
        .to raise_error(Lain::Prompt::ImpureSlot, /Time/)
    end
  end

  describe Lain::Prompt::Purity do
    it "accepts a read of a declared local" do
      expect(described_class.check!("epic_home", "t", locals: [:epic_home])).to be_nil
    end

    it "rejects the same read when it is not declared" do
      expect { described_class.check!("epic_home", "t") }.to raise_error(Lain::Prompt::ImpureSlot, /epic_home/)
    end
  end
end
