# frozen_string_literal: true

RSpec.describe Lain::CLI::Human do
  describe ".from" do
    it "is a human at the terminal when the run is not --non-interactive" do
      expect(described_class.from({ grace: 5 }).kind).to eq(:terminal)
    end

    it "is nobody under --non-interactive" do
      expect(described_class.from({ non_interactive: true }).kind).to eq(:none)
    end

    it "is remote under --non-interactive --human remote" do
      expect(described_class.from({ non_interactive: true, human: "remote" }).kind).to eq(:remote)
    end

    # The launch refuses the flag without --non-interactive, so a terminal chat must never read as remote.
    it "is at the terminal for --human remote without --non-interactive" do
      expect(described_class.from({ human: "remote" }).kind).to eq(:terminal)
    end

    it "reads the flag as Thor hands it, keyed by string" do
      options = Thor::CoreExt::HashWithIndifferentAccess.new("non_interactive" => true, "human" => "remote")

      expect(described_class.from(options).kind).to eq(:remote)
    end
  end

  # Outside the sandbox a phone's run runs only what a human approved, traced: any other call could reach the phone.
  it "is answered from away only when remote, which is what keeps unapproved bash confined" do
    expect(described_class::KINDS.to_h { [_1, described_class.new(kind: _1).answers_remotely?] })
      .to eq(terminal: false, remote: true, none: false)
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
