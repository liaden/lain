# frozen_string_literal: true

# {ApprovalView} and {InboxView} each folded a long row the same way, in their
# own words, because `neovim.rb`'s manifest loaded whichever came first before
# the other's constants existed. This spec pins the ONE shared definition
# both now read, and the one place it has to agree with the runtime.
RSpec.describe Lain::Frontend::Neovim::Fold do
  describe ".lines" do
    it "elides a line longer than the fold width and indents its remainder" do
      long = "x" * (described_class::WIDTH + 40)

      lines = described_class.lines(long)

      expect(lines.first).to end_with(described_class::ELISION)
      expect(lines.first.length).to eq(described_class::WIDTH)
      expect(lines.drop(1)).not_to be_empty
      expect(lines.drop(1)).to all(start_with(described_class::INDENT))
    end

    it "leaves a line shorter than the fold width unchanged and unindented" do
      short = "a short row"

      lines = described_class.lines(short)

      expect(lines).to eq([short])
    end

    # The cut and the wrap are two INDEPENDENT renderings of the same text, not
    # a head/tail split -- the wrap re-covers the whole string from byte 0 (see
    # {ApprovalView::BODY}'s "the opened fold has the whole sentence either
    # way"). So the property each one buys is checked on its own, not by
    # reassembling the two into the original.
    it "wraps the whole input losslessly, once its indent is stripped back off" do
      long = ("call " * 40).strip

      wrapped = described_class.wrap(long)

      expect(wrapped.map { |line| line.delete_prefix(described_class::INDENT) }.join).to eq(long)
    end

    it "cuts a true prefix of the input, elision aside" do
      long = ("call " * 40).strip

      cut = described_class.cut(long)

      expect(long).to start_with(cut.delete_suffix(described_class::ELISION))
    end
  end

  # A DRIFT GUARD, not a claim that anything folds -- that claim is
  # behavioural and belongs to `neovim_runtime_spec.rb`'s "folds" group,
  # against a real editor. This reads source on both sides because "the two
  # spellings are the same string" is a property of the source and of
  # nothing else.
  describe "the indent the runtime's boundary test agrees with" do
    def runtime_source(file) = File.read(File.join(Lain::Frontend::Neovim::RuntimeLoader::MODULES, file))

    it "marks a continuation with exactly the prefix 05_records.lua tests for" do
      pattern = runtime_source("05_records.lua")[/^local CONTINUATION = "\^([^"]*)"$/, 1]

      expect(pattern).to eq(described_class::INDENT)
    end
  end

  describe "one definition, read by both views" do
    it "is the only WIDTH, INDENT and ELISION the two views draw by" do
      expect(Lain::Frontend::Neovim::ApprovalView::WIDTH).to equal(described_class::WIDTH)
      expect(Lain::Frontend::Neovim::ApprovalView::INDENT).to equal(described_class::INDENT)
      expect(Lain::Frontend::Neovim::ApprovalView::ELISION).to equal(described_class::ELISION)
      expect(Lain::Frontend::Neovim::InboxView::WIDTH).to equal(described_class::WIDTH)
      expect(Lain::Frontend::Neovim::InboxView::INDENT).to equal(described_class::INDENT)
      expect(Lain::Frontend::Neovim::InboxView::ELISION).to equal(described_class::ELISION)
    end
  end
end
