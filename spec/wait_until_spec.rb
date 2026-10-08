# frozen_string_literal: true

require "async"

# A screen condition can hold for one look and not the next, as a pane redraws a typed line.
RSpec.describe WaitUntil do
  let(:looks) { [] }

  def flickering = [true, false].each.then { |answers| -> { answers.next.tap { |answer| looks << answer } } }

  describe "#wait_until" do
    it "holds once the condition was seen, and looks no more after that" do
      condition = flickering

      expect { wait_until(timeout: 1, reason: "the flicker") { condition.call } }.not_to raise_error
      expect(looks).to eq([true])
    end

    it "answers what the condition answered when it held" do
      expect(wait_until(timeout: 1) { :found }).to eq(:found)
    end

    it "still names the condition and the bound when it never held" do
      expect { wait_until(timeout: 0.05, reason: "the thing") { false } }
        .to raise_error(RuntimeError, "the thing never held within 0.05s")
    end
  end

  describe "#pumped_until" do
    it "holds once the condition was seen, and looks no more after that" do
      condition = flickering

      Sync do |task|
        expect { pumped_until(task, timeout: 1, reason: "the flicker") { condition.call } }.not_to raise_error
      end
      expect(looks).to eq([true])
    end

    it "still names the condition and the bound when it never held" do
      Sync do |task|
        expect { pumped_until(task, timeout: 0.05, reason: "the thing") { false } }
          .to raise_error(RuntimeError, "the thing never held within 0.05s")
      end
    end
  end
end
