# frozen_string_literal: true

RSpec.describe Lain::Tools::AstDump do
  subject(:tool) { described_class.new }

  it "dumps the CST, naming the singleton_method node distinct from a plain method" do
    result = tool.call(code: "def self.x; end", language: "ruby")

    expect(result).to be_ok
    expect(result.content).to include("singleton_method")
  end

  it "downcases the language before parsing" do
    result = tool.call(code: "def self.x; end", language: "RUBY")

    expect(result).to be_ok
    expect(result.content).to include("singleton_method")
  end

  it "reports an unsupported language as an error Result rather than raising" do
    result = tool.call(code: "x = 1", language: "cobol")

    expect(result).to have_attributes(is_error: true, content: /cobol/)
  end
end
