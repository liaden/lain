# frozen_string_literal: true

RSpec.describe Lain::CLI::Human do
  describe ".from" do
    it "is a human at the terminal when the run is not --non-interactive" do
      expect(described_class.from({ grace: 5 }).kind).to eq(:terminal)
    end

    it "is nobody under --non-interactive" do
      expect(described_class.from({ non_interactive: true }).kind).to eq(:none)
    end
  end

  def answers(kind)
    human = described_class.new(kind:)
    [human.answers_at_terminal?, human.can_be_asked?, human.ladder_refuses?]
  end

  it "answers at the terminal, can be asked, and leaves the ladder open when at the terminal" do
    expect(answers(:terminal)).to eq([true, true, false])
  end

  it "answers nowhere, cannot be asked, and has the ladder refuse when nobody is attached" do
    expect(answers(:none)).to eq([false, false, true])
  end

  it "can be asked away from the terminal, so the ladder stays open, when remote" do
    expect(answers(:remote)).to eq([false, true, false])
  end

  it "refuses a kind outside its closed set, naming it" do
    expect { described_class.new(kind: :phone) }.to raise_error(ArgumentError, /phone/)
  end

  it "is shareable, so who answers a run cannot change after launch" do
    expect(Ractor.shareable?(described_class.from({}))).to be(true)
  end
end
