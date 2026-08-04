# frozen_string_literal: true

RSpec.describe Lain::Question::Set do
  subject(:set) { described_class.new(questions: [single, multi]) }

  let(:single) do
    Lain::Question.new(id: "deploy", body: "Ship it?\n\n| when | risk |\n| --- | --- |\n| now | low |\n",
                       options: [Lain::Question::Option.new(id: "yes", label: "Ship now"),
                                 Lain::Question::Option.new(id: "no", label: "Hold")])
  end
  let(:multi) do
    Lain::Question.new(id: "reviewers", body: "Who reviews?", arity: "multi",
                       options: [Lain::Question::Option.new(id: "sandi", label: "Sandi"),
                                 Lain::Question::Option.new(id: "aaron", label: "Aaron")])
  end

  describe "construction" do
    it "is deeply frozen and Ractor-shareable" do
      expect(set).to be_deeply_frozen
    end

    it "keeps its questions in the order they were asked" do
      expect(set.map(&:id)).to eq(%w[deploy reviewers])
    end

    it "is Enumerable over its questions" do
      expect(set.size).to eq(2)
      expect(set.select(&:multi?)).to eq([multi])
    end

    it "fetches a question by id and reports whether it holds one" do
      expect(set.fetch("reviewers")).to eq(multi)
      expect(set.key?("reviewers")).to be(true)
      expect(set.key?("nobody")).to be(false)
      expect { set.fetch("nobody") }.to raise_error(KeyError, /nobody/)
    end

    # S6: `include Enumerable` on a Data puts Enumerable#to_h AHEAD of Data#to_h,
    # which would read the questions as [key, value] pairs. Nothing else pinned
    # this -- the shareability walk only calls #to_h on the FAILURE path, so
    # deleting the restored method left all the other examples green.
    it "answers #to_h with its Data members, not Enumerable's pair conversion" do
      expect(set.to_h).to eq(questions: [single, multi])
    end
  end

  describe "validation" do
    it "refuses a set with no questions" do
      expect { described_class.new(questions: []) }.to raise_error(ArgumentError, /question/)
    end

    it "refuses two questions sharing an id, naming the duplicate" do
      expect { described_class.new(questions: [single, single]) }.to raise_error(ArgumentError, /deploy/)
    end

    it "refuses a questions list that is not an Array" do
      expect { described_class.new(questions: single) }.to raise_error(ArgumentError, /Array/)
    end

    # S3: the same member policy the question applies to its options -- a member
    # arrives built, and `from_body` is the way in from raw data.
    it "refuses a raw question Hash, naming the class and the way in" do
      expect { described_class.new(questions: [single.to_body]) }
        .to raise_error(ArgumentError, /Question.*from_body/m)
    end
  end

  # S1: nothing bounded the SET, so 40 max-size questions serialized to ~2.6MB.
  # Per-set is the quantity that reaches the request, so per-set is what is
  # bounded -- over the bytes Canonical will actually emit.
  describe "size bounds" do
    def sized_set(count)
      described_class.new(questions: (1..count).map do |index|
        Lain::Question.new(id: "q#{index}", body: "x" * Lain::Question::MAX_BODY)
      end)
    end

    it "accepts a set whose serialized body is within the maximum" do
      expect(sized_set(3).size).to eq(3)
    end

    it "refuses a set whose serialized body is beyond it, naming the size" do
      maximum = described_class::MAX_SET
      expect { sized_set(4) }.to raise_error(ArgumentError, /#{maximum}/)
    end
  end

  describe "the body hash" do
    it "round-trips: rebuilt from its own body, the set equals the original" do
      expect(described_class.from_body(set.to_body)).to eq(set)
    end

    it "round-trips through Canonical.normalize, which is how it reaches an event" do
      expect(described_class.from_body(Lain::Canonical.normalize(set.to_body))).to eq(set)
    end

    it "canonicalizes without raising, and the normalized body is deeply frozen" do
      normalized = nil
      expect { normalized = Lain::Canonical.normalize(set.to_body) }.not_to raise_error
      expect(normalized).to be_deeply_frozen
    end

    it "hands back a fresh copy, so a caller may add its own keys beside ours" do
      body = set.to_body
      expect(body).not_to be_frozen
      expect(body.merge("question" => "2 questions").fetch("questions").size).to eq(2)
    end

    it "ignores keys it does not own, so a richer event body still rebuilds the set" do
      expect(described_class.from_body(set.to_body.merge("question" => "2 questions"))).to eq(set)
    end

    # S4: every one of these used to be a bare NoMethodError or a KeyError that
    # named neither the object being built nor which question was malformed.
    it "names the missing key when the body carries no questions" do
      expect { described_class.from_body({}) }.to raise_error(ArgumentError, /a question set body.*"questions"/)
    end

    it "refuses a body that is not a Hash, naming it" do
      expect { described_class.from_body("nope") }.to raise_error(ArgumentError, /Hash/)
    end

    it "refuses a questions value that is not an Array, naming it" do
      expect { described_class.from_body("questions" => "nope") }.to raise_error(ArgumentError, /Array/)
    end

    it "names WHICH question a malformed set could not read" do
      body = set.to_body
      body["questions"][1].delete("body")
      expect { described_class.from_body(body) }.to raise_error(ArgumentError, /question 2 .*"body"/m)
    end
  end
end
