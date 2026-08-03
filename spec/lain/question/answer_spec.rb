# frozen_string_literal: true

RSpec.describe Lain::Question::Answer do
  subject(:answer) do
    described_class.new(question_id: "deploy", option_ids: ["yes"], comment: "after the migration")
  end

  # Built from CODEPOINTS, never written as themselves: a literal invisible
  # character is unreadable in the diff, in the editor and in review, which is
  # how the AnswerSet half of this pair came to assert U+0020 under a name that
  # said U+00A0.
  let(:nbsp) { 0x00A0.chr(Encoding::UTF_8) }
  let(:zwsp) { 0x200B.chr(Encoding::UTF_8) }
  let(:zero_width) { [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF].map { |point| point.chr(Encoding::UTF_8) } }

  describe "construction" do
    it "is deeply frozen and Ractor-shareable" do
      expect(answer).to be_deeply_frozen
      expect(Ractor.shareable?(answer)).to be(true)
    end

    it "names the question it answers and the options it selected" do
      expect(answer.question_id).to eq("deploy")
      expect(answer.option_ids).to eq(["yes"])
      expect(answer.comment).to eq("after the migration")
    end

    it "keeps selection order, which is the order the human ticked them" do
      multi = described_class.new(question_id: "reviewers", option_ids: %w[aaron sandi])
      expect(multi.option_ids).to eq(%w[aaron sandi])
    end

    it "defaults to no selection and no comment" do
      bare = described_class.new(question_id: "deploy")
      expect(bare.option_ids).to eq([])
      expect(bare.comment).to be_nil
    end

    it "copies the option list, so the caller keeps its own Array" do
      given = ["yes"]
      built = described_class.new(question_id: "deploy", option_ids: given)
      given << "no"
      expect(built.option_ids).to eq(["yes"])
    end
  end

  describe "what counts as answered" do
    it "is answered when an option was selected" do
      expect(described_class.new(question_id: "deploy", option_ids: ["yes"])).to be_answered
    end

    it "is answered when prose was written and nothing was selected" do
      written = described_class.new(question_id: "deploy", comment: "not today")
      expect(written).to be_answered
      expect(written).not_to be_selected
      expect(written).to be_comment
    end

    # Ruling 9: submitting is never blocked, so an untouched question still
    # produces a record. "Missed" has to be representable, not absent.
    it "is unanswered when the human touched nothing" do
      expect(described_class.unanswered("deploy")).not_to be_answered
      expect(described_class.unanswered("deploy").question_id).to eq("deploy")
    end

    # The U+00A0 hole {Blankness} was written for: `strip` is ASCII-only,
    # so a non-breaking space passed `strip != ""`.
    it "reports no comment when the comment is a non-breaking space" do
      quiet = described_class.new(question_id: "deploy", comment: nbsp)
      expect(quiet.comment).to be_nil
      expect(quiet).not_to be_comment
      expect(quiet).not_to be_answered
    end

    it "reports no comment for a zero-width space, which is not space to any locale" do
      expect(described_class.new(question_id: "deploy", comment: zwsp).comment).to be_nil
    end

    it "keeps a comment that holds real text beside its whitespace" do
      expect(described_class.new(question_id: "deploy", comment: " ok \n").comment).to eq(" ok \n")
    end
  end

  describe "validation" do
    it "refuses a blank question id" do
      expect { described_class.new(question_id: "") }.to raise_error(ArgumentError, /question_id/)
    end

    it "refuses a question id holding a backtick, which the document renders inside a code span" do
      expect { described_class.new(question_id: "de`ploy") }.to raise_error(ArgumentError, /reserved/)
    end

    it "refuses an option id list that is not an Array" do
      expect { described_class.new(question_id: "deploy", option_ids: "yes") }
        .to raise_error(ArgumentError, /Array/)
    end

    it "refuses the same option selected twice, naming it" do
      expect { described_class.new(question_id: "deploy", option_ids: %w[yes yes]) }
        .to raise_error(ArgumentError, /yes/)
    end

    it "refuses a comment beyond the maximum, naming the size rather than truncating" do
      maximum = described_class::MAX_COMMENT
      expect { described_class.new(question_id: "deploy", comment: "x" * (maximum + 1)) }
        .to raise_error(ArgumentError, /#{maximum}/)
    end
  end

  describe "the body hash" do
    it "round-trips: rebuilt from its own body, the answer equals the original" do
      expect(described_class.from_body(answer.to_body)).to eq(answer)
    end

    it "round-trips an unanswered answer, so 'missed' survives the event" do
      unanswered = described_class.unanswered("deploy")
      expect(described_class.from_body(unanswered.to_body)).to eq(unanswered)
    end

    it "round-trips through Canonical.normalize, which is how it reaches an event" do
      expect(described_class.from_body(Lain::Canonical.normalize(answer.to_body))).to eq(answer)
    end

    it "hands back a fresh copy, so a caller may add its own keys beside ours" do
      body = answer.to_body
      expect(body).not_to be_frozen
      body["option_ids"] << "no"
      expect(answer.option_ids).to eq(["yes"])
    end

    it "names the missing key when the body does not say what it answers" do
      expect { described_class.from_body({}) }.to raise_error(ArgumentError, /an answer body.*"question_id"/)
    end

    it "refuses a body that is not a Hash, naming it" do
      expect { described_class.from_body("nope") }.to raise_error(ArgumentError, /Hash/)
    end
  end
end
