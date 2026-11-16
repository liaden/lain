# frozen_string_literal: true

RSpec.describe Lain::Frontend::InputPane::Draft do
  subject(:draft) { described_class.new(keys: described_class::Keys.for("\e[Z"), seen: true) }

  def typed(bytes) = [].tap { |events| draft.take(bytes) { |kind, value| events << [kind, value] } }

  it "hands a draft with a line end on as a paste, so the next prompt does not take it for Enter" do
    typed("\e[200~one\ntwo\e[201~")

    expect(draft.partial).to eq("\e[200~one\ntwo\e[201~")
  end

  it "counts a wide character as 2 columns of the rows the draft covers" do
    typed("漢" * 5)

    expect([draft.rows(10), draft.rows(9)]).to eq([1, 2])
  end

  describe "#empty?" do
    it "is true for a fresh draft and false once text is typed" do
      before = draft.empty?
      typed("a")

      expect([before, draft.empty?]).to eq([true, false])
    end

    it "is false while a paste is open and while a cut-off key is held" do
      typed("\e[200~abc")
      pasting = draft.empty?
      held = described_class.new(keys: described_class::Keys.for("\e[Z"), seen: true)
      held.take("\e[") { nil }

      expect([pasting, held.empty?]).to eq([false, false])
    end

    it "is true again after a discard of an open paste" do
      typed("\e[200~abc")
      draft.discard { nil }

      expect(draft.empty?).to be(true)
    end
  end

  # A draft is typed back into the editor as keys, so a line end or an escape
  # in it would act as Enter or as a key sequence rather than as text.
  describe ".typed_back" do
    it "writes out every control, so none of it acts as a key" do
      expect(described_class.typed_back("maybe\r\e[2J\t")).to eq("maybe\\r\\e[2J\\t")
    end

    it "carries a line end inside a paste, where no prompt takes it for Enter" do
      expect(described_class.typed_back("one\ntwo")).to eq("\e[200~one\ntwo\e[201~")
    end

    it "leaves plain text as it is" do
      expect(described_class.typed_back("maybe later, caf\u00e9")).to eq("maybe later, caf\u00e9")
    end
  end
end
