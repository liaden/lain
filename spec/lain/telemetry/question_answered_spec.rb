# frozen_string_literal: true

RSpec.describe Lain::Telemetry::QuestionAnswered do
  subject(:record) do
    described_class.new(question: "Owner blessings?", answer: "yes, both", requester: "reviewer", epic_slug: "nyotes")
  end

  it "journals the question, the answer, the requester and the slug under its own type" do
    expect(record.to_journal).to include("type" => "question_answered", "question" => "Owner blessings?",
                                         "answer" => "yes, both", "requester" => "reviewer", "epic_slug" => "nyotes")
  end

  it "leaves out a requester and a slug nobody named" do
    bare = described_class.new(question: "q?", answer: "a", requester: nil, epic_slug: nil)

    expect(bare.to_journal.keys).to contain_exactly("type", "question", "answer")
  end

  it "journals the surface that answered, and leaves it out when none was named" do
    phoned = described_class.new(question: "q?", answer: "a", answered_by: "remote:pixel")

    expect(phoned.to_journal).to include("answered_by" => "remote:pixel")
    expect(record.to_journal).not_to have_key("answered_by")
  end

  it "is deeply frozen, built from mutable strings" do
    mutable = described_class.new(question: +"q?", answer: +"a", requester: +"r", epic_slug: +"s",
                                  answered_by: +"remote:pixel")

    expect(mutable).to be_deeply_frozen
  end
end
