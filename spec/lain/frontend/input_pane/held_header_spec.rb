# frozen_string_literal: true

RSpec.describe Lain::Frontend::InputPane::HeldHeader do
  subject(:held) { described_class.new }

  let(:drawn) { { "kind" => "you", "generation" => 3, "header" => "model:0s" } }
  let(:newer) { drawn.merge("header" => "model:1s") }

  def released(ready: true) = [].tap { |frames| held.release(ready:) { |frame| frames << frame } }

  describe ".change?" do
    it "is true for a new header under the prompt already drawn" do
      expect(described_class.change?(drawn, newer)).to be(true)
    end

    it "is false for another prompt, the same header, or a countdown" do
      others = [newer.merge("generation" => 4), drawn, newer.merge("kind" => "countdown")]

      expect(others.map { |frame| described_class.change?(drawn, frame) }).to eq([false, false, false])
    end

    it "is false over a prompt drawn with no header, which has no rows to rewrite" do
      expect(described_class.change?(drawn.merge("header" => ""), newer)).to be(false)
    end
  end

  describe "#release" do
    it "yields the held frame once it is ready, and only once" do
      held.hold(newer)

      expect([released, released]).to eq([[newer], []])
    end

    it "keeps holding while it is not ready" do
      held.hold(newer)

      expect([released(ready: false), released]).to eq([[], [newer]])
    end

    it "yields nothing once dropped" do
      held.hold(newer)
      held.drop

      expect(released).to eq([])
    end
  end

  describe "#over" do
    it "answers the held frame in place of the drawn one, and the drawn one when nothing is held" do
      before = held.over(drawn)
      held.hold(newer)

      expect([before, held.over(drawn)]).to eq([drawn, newer])
    end
  end
end
