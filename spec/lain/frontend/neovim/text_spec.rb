# frozen_string_literal: true

RSpec.describe Lain::Frontend::Neovim::Text do
  describe "NEWLINES" do
    it "matches a run of any line break as one" do
      expect("a\r\n\nb c".gsub(described_class::NEWLINES, " ")).to eq("a b c")
    end
  end

  describe ".preview" do
    it "joins the text blocks and folds their newlines to spaces" do
      content = [{ "type" => "text", "text" => "a\nb" }, { "type" => "text", "text" => "c" }]

      expect(described_class.preview(content)).to eq("a b c")
    end

    it "names the block kinds when no text is present" do
      content = [{ "type" => "tool_use" }, { "type" => "image" }, { "type" => "tool_use" }]

      expect(described_class.preview(content)).to eq("(tool_use, image)")
    end

    it "says empty for no blocks" do
      expect(described_class.preview(nil)).to eq("(empty)")
    end
  end
end
