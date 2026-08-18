# frozen_string_literal: true

RSpec.describe Lain::Tools::TestPattern do
  subject(:tool) { described_class.new }

  it "reports the match count and, per match, the line and captures" do
    code = "def total(x)\n  x\nend"

    result = tool.call(pattern: "def $NAME($$$A)", code:, language: "ruby")

    expect(result).to be_ok
    expect(result.content).to match(/\A1 match:/)
    expect(result.content).to include("line 1")
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
    expect(result.content).to include("def (")
  end

  it "reports an unsupported language as an error Result rather than raising" do
    result = tool.call(pattern: "$A", code: "x = 1", language: "cobol")

    expect(result).to have_attributes(is_error: true, content: /cobol/)
  end

  # A match report is an ENUMERATION under {Lain::Tool::Bounds}' stated
  # boundary -- the same shape {Lain::Tools::Grep} and {Lain::Tools::AstSearch}
  # already cap -- so it caps and announces the cut IN BAND. The header already
  # states the true count, so the notice completes a disclosure this tool had
  # half of: the count is what the pattern found, the rows are what fits.
  describe "the enumeration bound" do
    let(:bound) { described_class::BOUND }
    let(:overflow) { 5 }

    def many_methods(count)
      Array.new(count) { |i| "def m#{format("%05d", i)}()\nend\n" }.join
    end

    it "caps an oversized match report and discloses the cap and the true count in band" do
      total = bound.limit + overflow

      rows = tool.call(pattern: "def $NAME($$$A)", code: many_methods(total), language: "ruby")
                 .content.split("\n")

      expect(rows.first).to eq("#{total} matches:")
      expect(rows.length).to eq(bound.limit + 2)
      expect(rows.last).to eq("... capped at #{bound.limit} of #{total} matches")
    end

    it "caps after the match ordering, so the survivors are the first matches in the source" do
      rows = tool.call(pattern: "def $NAME($$$A)", code: many_methods(bound.limit + overflow), language: "ruby")
                 .content.split("\n")

      expect(rows[1]).to eq('  1. line 1: NAME="m00000"')
      expect(rows[bound.limit]).to eq("  #{bound.limit}. line #{(2 * bound.limit) - 1}: " \
                                      "NAME=\"m#{format("%05d", bound.limit - 1)}\"")
    end

    it "leaves a match report within the cap byte-identical" do
      result = tool.call(pattern: "def $NAME($$$A)", code: "def total(x)\nend\n", language: "ruby")

      expect(result.content).to eq("1 match:\n  1. line 1: NAME=\"total\"")
    end
  end
end
