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
      expect(Ractor.shareable?(described_class.from_answer(fields))).to be(true)
    end
  end

  describe "#to_s" do
    it "renders the preamble, then each heading over its text" do
      text = described_class.from_answer(fields).to_s

      expect(text).to start_with(Lain::Oracle::Handoff::PREAMBLE)
      expect(text).to include("## Goal\n\nship the parser").and include("## Next step\n\nwrite parser.rb")
    end
  end
end
