# frozen_string_literal: true

RSpec.describe Lain::Frontend::Neovim::HeldNotes do
  let(:asked) { [] }

  def inlet(&answer)
    asks = asked
    Class.new do
      define_method(:ask_review_notes) do |token|
        asks << token
        answer&.call(token)
        nil
      end
    end.new
  end

  it "returns the count the editor answers with for that ask" do
    notes = nil
    notes = described_class.new(rpc: inlet { |token| Thread.new { notes.answered(token, 4) } })

    expect(notes.count).to eq(4)
  end

  it "ignores an answer to an ask nobody is waiting on" do
    notes = described_class.new(rpc: inlet, timeout: 0.05)

    expect(notes.answered("stale", 9)).to be_nil
  end

  it "ignores an answer carrying another ask's token while it waits" do
    notes = nil
    notes = described_class.new(rpc: inlet { |_token| Thread.new { notes.answered("other", 9) } }, timeout: 0.05)

    expect { notes.count }.to raise_error(Lain::Error, described_class::UNANSWERED)
  end

  it "holds nothing when the editor is gone" do
    notes = described_class.new(rpc: inlet { raise ClosedQueueError }, timeout: 0.05)

    expect(notes.count).to eq(0)
  end

  it "refuses in words, rather than reading 0, when the editor's queue is full" do
    notes = described_class.new(rpc: inlet { raise ThreadError }, timeout: 0.05)

    expect { notes.count }.to raise_error(Lain::Error, described_class::UNANSWERED)
  end

  it "refuses in words when an attached editor never answers" do
    notes = described_class.new(rpc: inlet, timeout: 0.05)

    expect { notes.count }.to raise_error(Lain::Error, described_class::UNANSWERED)
  end
end
