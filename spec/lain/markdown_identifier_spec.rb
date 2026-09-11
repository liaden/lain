# frozen_string_literal: true

RSpec.describe Lain::MarkdownIdentifier do
  describe "::RESERVED" do
    it "reserves exactly a backtick, a carriage return, and a line feed" do
      expect("a`b".match?(described_class::RESERVED)).to be(true)
      expect("a\rb".match?(described_class::RESERVED)).to be(true)
      expect("a\nb".match?(described_class::RESERVED)).to be(true)
      expect("clean".match?(described_class::RESERVED)).to be(false)
    end
  end

  describe ".check!" do
    let(:grammars) do
      { "`" => described_class::BACKTICK_GRAMMAR, "\r" => "a fixture heading", "\n" => "a fixture heading" }
    end

    it "hands the id back unchanged when it holds none of the reserved characters" do
      expect(described_class.check!("clean", "a fixture id", grammars:, error: ArgumentError)).to eq("clean")
    end

    it "raises the given error naming the field, the value, the offender, and its grammar" do
      expect { described_class.check!("bad`id", "a fixture id", grammars:, error: ArgumentError) }
        .to raise_error(ArgumentError,
                        'a fixture id "bad`id" contains "`", a character reserved for the `id` backtick delimiters')
    end

    it "checks against a caller-supplied reserved set instead of the default" do
      grammars = { "!" => "a fixture bang" }

      expect { described_class.check!("a!b", "a fixture id", grammars:, error: ArgumentError, reserved: /!/) }
        .to raise_error(ArgumentError, /a fixture bang/)
    end

    it "fails loudly rather than mislabelling a reserved character its caller forgot to name" do
      expect { described_class.check!("bad`id", "a fixture id", grammars: {}, error: ArgumentError) }
        .to raise_error(KeyError)
    end
  end

  # The property this object exists to establish: Epic::Issue, Plan::Step, and
  # Question each mint ids under this one rule, so a backtick refuses
  # identically wherever an id is minted -- and Question's own extension (the
  # zero-width characters that make an id invisible once rendered, its own
  # hazard) must not leak into the other two.
  describe "shared across Epic::Issue, Plan::Step, and Question" do
    def refusal
      yield
      nil
    rescue Lain::Error, ArgumentError => e
      e.message
    end

    it "refuses a backtick with the same grammar phrase in all three" do
      messages = [
        refusal { Lain::Epic::Issue.new(id: "a`b", title: "t") },
        refusal { Lain::Plan::Step.new(id: "a`b", title: "t", size: "S") },
        refusal { Lain::Question.new(id: "a`b", body: "body") }
      ]

      expect(messages).to all(include(described_class::BACKTICK_GRAMMAR))
    end

    it "refuses U+200B only on a question id" do
      expect { Lain::Question.new(id: "a​b", body: "body") }.to raise_error(ArgumentError, /see/)
      expect { Lain::Epic::Issue.new(id: "a​b", title: "t") }.not_to raise_error
      expect { Lain::Plan::Step.new(id: "a​b", title: "t", size: "S") }.not_to raise_error
    end
  end
end
