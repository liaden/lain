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
end
