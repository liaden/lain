# frozen_string_literal: true

require "json"

# A generic TOML parse, by the same `toml` crate cargo reads a manifest with. Ruby has no TOML parser, so the
# oracle is toml-test's own expected JSON (vendored under spec/fixtures/toml-test), never the binding's output.
RSpec.describe Lain::Ext::Toml do
  fixtures = File.expand_path("../../fixtures/toml-test", __dir__)
  valid = Dir.glob("valid/**/*.toml", base: fixtures).sort
  invalid = Dir.glob("invalid/**/*.toml", base: fixtures).sort

  def read(root, name) = File.read(File.join(root, name), encoding: Encoding::UTF_8)

  # toml-test compares as the TOML spec says values are equal, not as text: a time may omit its seconds, a
  # fraction's trailing zeros are not significant, a NaN has no sign, and 0.0 differs from -0.0.
  def agree?(actual, tree)
    case tree
    when Array then actual.is_a?(Array) && actual.size == tree.size && actual.zip(tree).all? { agree?(*_1) }
    when Hash then leaf?(tree) ? leaf_agrees?(actual, tree) : table_agrees?(actual, tree)
    end
  end

  def leaf?(tree) = tree.keys.sort == %w[type value] && tree["type"].is_a?(String)

  def table_agrees?(actual, tree)
    actual.is_a?(Hash) && actual.keys.sort == tree.keys.sort && tree.all? { |key, item| agree?(actual[key], item) }
  end

  def leaf_agrees?(actual, leaf)
    type, value = leaf.values_at("type", "value")
    case type
    when "integer" then actual == Integer(value, 10) && actual.is_a?(Integer)
    when "float" then float_agrees?(actual, value)
    when "bool" then actual == (value == "true")
    when /\Adate|\Atime/ then actual.is_a?(String) && moment(actual) == moment(value)
    else actual == value && actual.is_a?(String)
    end
  end

  def float_agrees?(actual, text)
    return false unless actual.is_a?(Float)

    case text
    when /nan/ then actual.nan?
    when "inf", "+inf" then actual == Float::INFINITY
    when "-inf" then actual == -Float::INFINITY
    else [actual].pack("G") == [Float(text)].pack("G")
    end
  end

  def moment(text)
    padded = text.sub(/\A((?:\d{4}-\d\d-\d\d[Tt ])?\d\d:\d\d)(?!:)/, '\\1:00')
    padded.sub(/(\.\d*?)0+(?=\D|\z)/, '\\1').sub(/\.(?=\D|\z)/, "").downcase.tr(" ", "t")
  end

  def frozen_throughout?(value)
    case value
    when Hash then value.frozen? && value.all? { |key, item| key.frozen? && frozen_throughout?(item) }
    when Array then value.frozen? && value.all? { frozen_throughout?(_1) }
    else value.frozen?
    end
  end

  it "has valid and invalid cases to read, TOML 1.1 included" do
    expect([valid.size, invalid.size]).to all(be > 100)
    expect(valid).to include(a_string_matching(%r{\Avalid/key/dotted-01}), a_string_matching(%r{\Avalid/inline-table/}))
  end

  describe ".parse" do
    it "reads every valid case as its expected JSON, frozen throughout" do
      wrong = valid.reject do |name|
        expected = JSON.parse(read(fixtures, name.sub(/\.toml\z/, ".json")))
        parsed = described_class.parse(read(fixtures, name))
        agree?(parsed, expected) && Ractor.shareable?(parsed) && frozen_throughout?(parsed)
      end

      expect(wrong).to be_empty
    end

    it "refuses every invalid case as Invalid, with the parser's message" do
      accepted = invalid.reject do |name|
        described_class.parse(read(fixtures, name))
        false
      rescue Lain::Ext::Toml::Invalid => e
        e.message.match?(/\S/)
      end

      expect(accepted).to be_empty
    end

    it "refuses input nested past the parser's recursion limit, without overflowing the stack" do
      deep = [
        "a = #{"[" * 100_000}#{"]" * 100_000}\n",
        "a = #{"{ a = " * 100_000}1#{" }" * 100_000}\n",
        "#{(["a"] * 100_000).join(".")} = 1\n"
      ]

      deep.each { |text| expect { described_class.parse(text) }.to raise_error(Lain::Ext::Toml::Invalid) }
    end

    it "keeps the parser's line and column in the message" do
      expect { described_class.parse("a = 1\nb = \n") }
        .to raise_error(Lain::Ext::Toml::Invalid, /line 2, column 5/)
    end

    it "is a Lain::Error, so one rescue covers the extension's refusals" do
      expect(Lain::Ext::Toml::Invalid.ancestors).to include(Lain::Error)
    end

    it "reads a String whatever its encoding tag, as a manifest's bytes arrive off disk" do
      expect(described_class.parse("name = \"é\"\n".b)).to eq({ "name" => "é" })
    end

    it "refuses a non-String as a TypeError, since the caller's argument is the defect" do
      expect { described_class.parse(nil) }.to raise_error(TypeError)
    end
  end
end
