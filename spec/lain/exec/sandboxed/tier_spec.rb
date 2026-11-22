# frozen_string_literal: true

RSpec.describe Lain::Exec::Sandboxed::Tier do
  let(:profile) { Lain::Confine::Profile.reader(root: "/p", home: "/h") }
  let(:tier) { "#{profile.tier_line}\n" }
  let(:line) { described_class.new(net_enforced: true) }

  describe ".last_line" do
    it "finds the line at the end of a text" do
      expect(described_class.last_line("bad\n#{tier}")).to eq(tier)
    end

    it "finds it after bytes that are not valid UTF-8, which a timeout report may quote" do
      expect(described_class.last_line("caf\xE9\n#{tier}")).to eq(tier)
    end

    it "answers nil for a text that does not end in one" do
      expect(described_class.last_line("[ran: reader]\nmore\n")).to be_nil
    end
  end

  describe "#over" do
    it "ends the capture's stderr with the line, on a line of its own, leaving the size alone" do
      capture = Lain::Exec::Capture.new(exit_status: 1, stdout: "", stderr: "bad", size: 3, ceiling: 4096)

      expect(line.over(profile) { capture }).to have_attributes(stderr: "bad\n#{tier}", size: 3, ceiling: 4096)
    end

    it "ends a timeout's message with the line and keeps the original as its cause" do
      original = Lain::Exec::Timeout.new("partial")

      raised = begin
        line.over(profile) { raise original }
      rescue Lain::Exec::Timeout => e
        e
      end

      expect([raised.message, raised.cause]).to eq(["partial\n#{tier}", original])
    end
  end
end
