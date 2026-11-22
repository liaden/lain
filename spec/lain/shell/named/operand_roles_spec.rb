# frozen_string_literal: true

RSpec.describe Lain::Shell::Named::OperandRoles do
  describe ".of" do
    it "reads a searcher's first operand as its pattern and the rest as files" do
      expect(described_class.of("grep", 3)).to eq(%i[pattern file file])
      expect(described_class.of("rg", 2)).to eq(%i[pattern file])
    end

    it "reads every operand of echo as text" do
      expect(described_class.of("echo", 3)).to eq(%i[text text text])
    end

    it "reads a script, a filter and a format before their files" do
      expect(described_class.of("sed", 2)).to eq(%i[script file])
      expect(described_class.of("awk", 2)).to eq(%i[script file])
      expect(described_class.of("jq", 2)).to eq(%i[filter file])
      expect(described_class.of("printf", 2)).to eq(%i[format file])
    end

    it "reads every operand as a file once an option carries the program's text" do
      expect(described_class.of("grep", 2, displaced: true)).to eq(%i[file file])
      expect(described_class.of("jq", 2, displaced: true)).to eq(%i[file file])
    end

    it "keeps a file role for a program it does not list" do
      expect(described_class.of("frobnicate", 2)).to eq(%i[file file])
    end

    it "names no role for no operands" do
      expect(described_class.of("grep", 0)).to eq([])
    end
  end

  describe ".displaced?" do
    def displaced?(program, words)
      described_class.displaced?(program, Lain::Shell::Named.const_get(:Argv).new(words, program))
    end

    it "is true when an option, short or long, carries the program's text" do
      expect(displaced?("grep", %w[-e abc f])).to be(true)
      expect(displaced?("grep", %w[-if pats f])).to be(true)
      expect(displaced?("grep", %w[--file=pats f])).to be(true)
      expect(displaced?("sed", %w[--expression s/a/b/ f])).to be(true)
      expect(displaced?("rg", %w[--files .])).to be(true)
      expect(displaced?("ack", %w[-f dir])).to be(true)
    end

    it "is true for an abbreviated long option, which GNU getopt accepts" do
      expect(displaced?("grep", %w[--reg=x f])).to be(true)
      expect(displaced?("sed", %w[--expr=s/a/b/ f])).to be(true)
    end

    it "is true for a jq option whose value Argv cannot separate" do
      expect(displaced?("jq", %w[-L lib .x b.json])).to be(true)
      expect(displaced?("jq", %w[--arg n v .x b.json])).to be(true)
    end

    it "is false for options that leave the text in the first operand" do
      expect(displaced?("grep", %w[-E -n abc f])).to be(false)
      expect(displaced?("grep", %w[--max-count=1 abc f])).to be(false)
      expect(displaced?("grep", %w[-- -e f])).to be(false)
      expect(displaced?("jq", %w[-r .x b.json])).to be(false)
    end

    it "is false for a program it does not list" do
      expect(displaced?("frobnicate", %w[-e x f])).to be(false)
    end
  end
end
