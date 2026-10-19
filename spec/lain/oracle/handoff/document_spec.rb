# frozen_string_literal: true

RSpec.describe Lain::Oracle::Handoff::Document do
  let(:fields) do
    { "goal" => "ship the parser", "progress" => "lexer done", "files_and_decisions" => "lexer.rb, no regexes",
      "open_todos" => "the parser", "next_step" => "write parser.rb" }
  end

  describe ".from_answer" do
    it "reads the five fields the oracle answered" do
      document = described_class.from_answer(fields)

      expect([document.goal, document.progress, document.files_and_decisions, document.open_todos,
              document.next_step]).to eq(fields.values)
    end

    it "is deeply frozen" do
      expect(described_class.from_answer(fields)).to be_deeply_frozen
    end
  end

  describe "#to_s" do
    it "renders the preamble, then each heading over its text" do
      text = described_class.from_answer(fields).to_s

      expect(text).to start_with(Lain::Oracle::Handoff::PREAMBLE)
      expect(text).to include("## Goal\n\nship the parser").and include("## Where the work stood\n\nwrite parser.rb")
    end

    it "defers to the human's newest message" do
      text = described_class.from_answer(fields).to_s

      expect(text).to match(/newest message.*precedence/i).and match(/only if.*ask/i)
    end
  end
end
