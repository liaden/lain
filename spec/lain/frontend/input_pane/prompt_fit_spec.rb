# frozen_string_literal: true

RSpec.describe Lain::Frontend::InputPane::PromptFit do
  subject(:fit) { described_class.new(rows:, columns: 80) }

  let(:rows) { 26 }
  let(:call) { "FIRST #{"x" * 2600} LAST" }
  let(:reasons) { [] }
  let(:parts) do
    { "lead" => "13:14:01 agent asks:", "call" => call, "reasons" => reasons,
      "tail" => "auto-denies in 5:00, approve? [y/N] " }
  end
  let(:whole) { "13:14:01 agent asks (auto-denies in 5:00): approve #{call}? [y/N] " }

  it "leaves a prompt that fits as the one line it was" do
    short = parts.merge("call" => "bash(ls)")

    expect(fit.call(short, "the whole line")).to eq(["the whole line"])
  end

  it "ends on the tail, which holds the y/N and the deadline" do
    expect(fit.call(parts, whole).last).to eq("auto-denies in 5:00, approve? [y/N] ")
  end

  it "says above the tail how many bytes are hidden and where the whole call is" do
    shown = fit.call(parts, whole)

    expect(shown[-2]).to match(%r{\A\d+ bytes of the call are hidden; the full call is in lain://approval\z})
  end

  it "keeps both ends of the call and counts exactly the bytes it cut" do
    shown = fit.call(parts, whole)
    hidden = shown[-2][/\A\d+/].to_i
    kept = (shown[1...-2] - [described_class::CUT]).join

    expect([kept.start_with?("FIRST"), kept.end_with?("LAST"), kept.bytesize + hidden])
      .to eq([true, true, call.bytesize])
  end

  it "fits the rows it was given, however long the call" do
    expect(fit.call(parts, whole).size).to be <= rows - 1
  end

  it "wraps nothing wider than the columns" do
    expect(fit.call(parts, whole).map(&:size).max).to be <= 80
  end

  it "cuts the middle of long reasons too, keeping the tail" do
    long = parts.merge("reasons" => ["REASON #{"y" * 1500} END"])
    shown = fit.call(long, whole)

    expect([shown.join("\n").include?("REASON"), shown.join("\n").include?("END"), shown.last])
      .to eq([true, true, "auto-denies in 5:00, approve? [y/N] "])
  end

  context "with a lead as long as the call" do
    let(:parts) { super().merge("lead" => "LEADFIRST #{"y" * 3000} LEADLAST") }

    it "cuts the lead's middle too and never draws more rows than the pane has" do
      shown = fit.call(parts, whole)

      expect([shown.size <= rows - 1, shown.join("\n").include?("LEADFIRST"), shown.join("\n").include?("LEADLAST"),
              shown.last]).to eq([true, true, true, "auto-denies in 5:00, approve? [y/N] "])
    end

    it "counts the lead's hidden bytes in the note" do
      shown = fit.call(parts, whole)
      kept = (shown[0...-2] - [described_class::CUT]).join

      expect(kept.bytesize + shown[-2][/\A\d+/].to_i).to eq(parts["lead"].bytesize + call.bytesize)
    end
  end

  [1, 2, 3, 4].each do |tiny|
    context "with a pane of #{tiny} rows, fewer than the lead and the frame need" do
      let(:rows) { tiny }
      let(:parts) { super().merge("lead" => "lead " * 40) }

      it "draws no more rows than the pane has and still ends on the tail" do
        shown = fit.call(parts, whole)

        expect([shown.size <= [rows - 1, 1].max, shown.last]).to eq([true, "auto-denies in 5:00, approve? [y/N] "])
      end
    end
  end

  context "with a pane too short for anything but the frame" do
    let(:rows) { 4 }

    it "still ends on the tail" do
      expect(fit.call(parts, whole).last).to eq("auto-denies in 5:00, approve? [y/N] ")
    end
  end
end
