# frozen_string_literal: true

RSpec.describe Lain::Tools::AstDump do
  subject(:tool) { described_class.new }

  it "has a model-facing name and description" do
    expect(tool.name).to eq("ast_dump")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  it "is not gated by approval -- read-only, no subprocess" do
    expect(tool.requires_approval?).to be(false)
  end

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
