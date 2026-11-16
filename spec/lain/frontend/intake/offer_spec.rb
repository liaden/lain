# frozen_string_literal: true

RSpec.describe Lain::Frontend::Intake::Offer do
  subject(:offer) { described_class.new(line) }

  let(:line) { "/review https://github.com/fuze/api/pull/12" }

  def yielded(method, *) = [].tap { |out| offer.public_send(method, *) { |value| out << value } }

  it "asks with the line it will send" do
    expect(offer.stamped).to eq("lain queue: #{line}  (Enter opens, x drops)")
  end

  it "takes Enter and x as answers, and nothing else" do
    expect(["", "  ", "x", " x ", "maybe", "X", "/review"].map { |text| offer.takes?(text) })
      .to eq([true, true, true, true, false, false, false])
  end

  it "says what does answer it when it is refused" do
    expect(yielded(:refused)).to eq(["lain queue: Enter opens #{line}, x drops it; what you typed waits at you>"])
  end

  it "says it is waiting while another prompt holds the terminal" do
    expect(yielded(:queued)).to eq(["lain queue: a review offer waits behind the prompt in front of you"])
  end

  it "gives its line only on Enter" do
    expect([yielded(:opened, ""), yielded(:opened, "x"), yielded(:opened, nil)]).to eq([[line], [], []])
  end

  it "keeps what was typed at it, in order, as 1 draft for you>" do
    offer.withhold("maybe")
    offer.withhold("later")

    expect(offer.draft).to eq("maybe later")
  end

  it "has no draft when nothing was typed at it" do
    expect(offer.draft).to eq("")
  end
end
