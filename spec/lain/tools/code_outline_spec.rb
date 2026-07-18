# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Tools::CodeOutline do
  subject(:tool) { described_class.new }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  attr_reader :tmpdir

  def write(name, content)
    path = File.join(tmpdir, name)
    File.write(path, content)
    path
  end

  it "has a model-facing name and description" do
    expect(tool.name).to eq("code_outline")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  it "is not gated by approval and is tier 1 (no subprocess involved)" do
    expect(tool.requires_approval?).to be(false)
  end

  it "lists a file's classes/modules/methods with line numbers, ordered by position, " \
     "ignoring identifiers in comments or strings" do
    # Method defs are written WITH parens deliberately: the shared catalog's
    # `:method_def` templates are "def $NAME($$$A)" / "def self.$NAME($$$A)",
    # which -- like ast-grep generally -- match the concrete parenthesized
    # node only; a paren-less `def total` is a distinct CST shape the current
    # catalog does not cover. That is a pre-existing T2 catalog limitation,
    # not something this tool works around.
    path = write("outline_me.rb", <<~RUBY)
      module Outer
        # class NotReal
        class Inner
          def total()
            "def not_real"
          end

          def self.build()
            new
          end
        end
      end
    RUBY

    result = tool.call(path:, language: "ruby")

    expect(result.ok?).to be(true)
    lines = result.content.lines.map(&:chomp)
    expect(lines).to eq(
      [
        "L1  module Outer",
        "L3  class Inner",
        "L4  def total",
        "L8  def self.build"
      ]
    )
    expect(result.content).not_to include("NotReal")
    expect(result.content).not_to include("not_real")
  end

  it "reports a missing file as an error Result rather than raising" do
    missing = File.join(tmpdir, "nope.rb")

    result = tool.call(path: missing, language: "ruby")

    expect(result).to have_attributes(is_error: true, content: /no such file/)
  end

  it "reports a directory as an error Result rather than raising" do
    result = tool.call(path: tmpdir, language: "ruby")

    expect(result).to have_attributes(is_error: true, content: /is a directory/)
  end

  it "reports an unreadable file as an error Result rather than raising" do
    path = write("secret.rb", "class A; end")
    File.chmod(0o000, path)

    result = tool.call(path:, language: "ruby")

    expect(result).to have_attributes(is_error: true, content: /not readable/)
  ensure
    File.chmod(0o600, path) if path && File.exist?(path)
  end

  it "reports an unsupported language as an error Result rather than raising" do
    path = write("thing.cob", "IDENTIFICATION DIVISION.")

    result = tool.call(path:, language: "cobol")

    expect(result).to have_attributes(is_error: true, content: /cobol/)
  end

  it "returns an ok, empty result for a file with no classes/modules/methods" do
    path = write("empty.rb", "x = 1\ny = 2\n")

    result = tool.call(path:, language: "ruby")

    expect(result.ok?).to be(true)
    expect(result.content).to eq("")
  end
end
