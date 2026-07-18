# frozen_string_literal: true

RSpec.describe Lain::Tools::TestPattern do
  subject(:tool) { described_class.new }

  it "has a model-facing name and description" do
    expect(tool.name).to eq("test_pattern")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  it "is not gated by approval -- read-only, no subprocess" do
    expect(tool.requires_approval?).to be(false)
  end

  it "reports the match count and, per match, the line and captures" do
    code = "def total(x)\n  x\nend"

    result = tool.call(pattern: "def $NAME($$$A)", code:, language: "ruby")

    expect(result).to be_ok
    expect(result.content).to match(/\A1 match:/)
    expect(result.content).to match(/line 1/)
    expect(result.content).to include('NAME="total"')
  end

  it "reports every match when there is more than one" do
    code = "def one(a)\nend\n\ndef two(b)\nend\n"

    result = tool.call(pattern: "def $NAME($$$A)", code:, language: "ruby")

    expect(result).to be_ok
    expect(result.content).to match(/\A2 matches:/)
    expect(result.content).to include('NAME="one"')
    expect(result.content).to include('NAME="two"')
  end

  it "surfaces a silent under-match: a singleton method def is a distinct node the pattern misses" do
    code = <<~RUBY
      def total(x)
        x
      end

      def self.x
      end
    RUBY

    result = tool.call(pattern: "def $NAME($$$A)", code:, language: "ruby")

    expect(result).to be_ok
    # The source has two method defs; the report names only one match --
    # the discrepancy the model is meant to notice and go chase with ast_dump.
    expect(result.content).to match(/\A1 match:/)
    expect(result.content).to include('NAME="total"')
    expect(result.content).not_to include('NAME="x"')
  end

  it "reports a valid pattern with zero matches as an explicit ok result, not an error" do
    result = tool.call(pattern: "$RECV.save", code: "x = 1", language: "ruby")

    expect(result).to be_ok
    expect(result.content).to eq("0 matches.")
  end

  it "reports a malformed pattern as an error Result naming the pattern" do
    result = tool.call(pattern: "def (", code: "x = 1", language: "ruby")

    expect(result).to have_attributes(is_error: true)
    expect(result.content).to match(/def \(/)
  end

  it "reports an unsupported language as an error Result rather than raising" do
    result = tool.call(pattern: "$A", code: "x = 1", language: "cobol")

    expect(result).to have_attributes(is_error: true, content: /cobol/)
  end
end
