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

  it "reports a source nested past the depth cap as an error Result naming the cap, not a raise" do
    result = tool.call(code: "#{"(" * 2000}1#{")" * 2000}", language: "ruby")

    expect(result).to have_attributes(is_error: true, content: /capped at/)
  end

  it "truncates an oversized dump and discloses the cap, mirroring ast_search rather than refusing" do
    # An ordinary 7 KB source file dumps past the output cap. Refusing it left
    # the model nothing to work with; the OUTER structure it gets here is the
    # half that answers "what node kind is this?".
    result = tool.call(code: "x = 1\n" * 20_000, language: "ruby")

    expect(result).to be_ok
    expect(result.content).to start_with("program\n").and end_with("... capped at 65536 bytes\n")
  end

  it "reports an unsupported language as an error Result rather than raising" do
    result = tool.call(code: "x = 1", language: "cobol")

    expect(result).to have_attributes(is_error: true, content: /cobol/)
  end
end
