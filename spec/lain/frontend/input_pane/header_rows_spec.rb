# frozen_string_literal: true

RSpec.describe Lain::Frontend::InputPane::HeaderRows do
  subject(:rows) { described_class.new(tty:) }

  let(:written) { [] }
  let(:tty) { Struct.new(:written) { def print_prompt(text) = written << text }.new(written) }

  describe ".same_count?" do
    it "is true for headers of one row count" do
      expect(described_class.same_count?("a\nb", "c\nd")).to be(true)
    end

    it "is false for another row count, or for no rows to rewrite" do
      expect([described_class.same_count?("a", "c\nd"), described_class.same_count?("a", "")]).to eq([false, false])
    end
  end

  describe "#rewrite" do
    it "rewrites each row in place between a saved and a restored cursor" do
      rows.rewrite("one\ntwo")

      expect(written).to eq(["\e7\e[2A\r\e[Kone\n\r\e[Ktwo\n\e8"])
    end
  end

  describe "#over" do
    it "clears the row the cursor is on and prints the header over it" do
      rows.over("model:0s")

      expect(written).to eq(["\r\e[Kmodel:0s\n"])
    end

    it "prints nothing for an empty header" do
      rows.over("")
      rows.over(nil)

      expect(written).to be_empty
    end
  end

  describe "#hint" do
    let(:frame) { { "kind" => "you", "generation" => 2 } }

    it "names the multiline keys once per you prompt" do
      2.times { rows.hint(frame) }

      expect(written).to eq(["\r\e[KShift+Enter or Alt+Enter for a new line\n"])
    end

    it "hints again at the next prompt, and never over a countdown" do
      rows.hint(frame)
      rows.hint(frame.merge("generation" => 3))
      rows.hint(frame.merge("kind" => "countdown", "generation" => 4))

      expect(written.size).to eq(2)
    end
  end
end
