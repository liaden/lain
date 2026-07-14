# frozen_string_literal: true

# Speculative branching is beam search over agent behaviour: fork one node into
# N trajectories (O(1), because Timeline#fork is identity over a shared Store),
# run each, score each with a grader, and keep the best. This proves the shape
# with a deterministic Grader::Fixture so the selection is reproducible.
RSpec.describe Lain::Bench::Speculative do
  let(:store) { Lain::Store.new }
  let(:base) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "What is the capital of France?" }])
  end

  # Grades a trajectory (a Timeline): one point for having answered, one for
  # naming Paris. Different branches earn different fractions, so argmax has
  # something to choose.
  let(:grader) do
    Lain::Grader::Fixture.new("good answer") do |f|
      f.check("answered") { |tl| tl.to_a.any? { |turn| turn.role == "assistant" } }
      f.check("names Paris") { |tl| answer_text(tl).include?("Paris") }
    end
  end

  def answer_text(timeline)
    timeline.to_a.select { |turn| turn.role == "assistant" }
                 .flat_map(&:content).filter_map { |block| block["text"] }.join(" ")
  end

  def answering(text)
    ->(timeline) { timeline.commit(role: :assistant, content: [{ "type" => "text", "text" => text }]) }
  end

  let(:branches) { [answering("It is Lyon."), answering("The capital is Paris."), answering("Marseille, I think.")] }

  subject(:speculative) { described_class.new(grader:) }

  it "forks N trajectories, scores each, and selects the max" do
    selection = speculative.search(base, branches:)

    expect(selection.candidates.size).to eq(3)
    expect(selection.grade.score).to eq(1.0)
    expect(answer_text(selection.best)).to include("Paris")
  end

  it "ranks every candidate with a grade, not just the winner" do
    selection = speculative.search(base, branches:)

    expect(selection.candidates.map { |c| c.grade.score }).to eq([0.5, 1.0, 0.5])
  end

  it "keeps the fork O(1): every trajectory shares the one Store and the common prefix" do
    selection = speculative.search(base, branches:)

    selection.candidates.each do |candidate|
      expect(candidate.trajectory.store).to be(store)
      expect(candidate.trajectory.meet(base)).to eq(base)
    end
  end

  it "is deterministic: the same branches select the same trajectory twice" do
    first = speculative.search(base, branches:)
    second = speculative.search(base, branches:)
    expect(first.best).to eq(second.best)
  end

  it "breaks ties toward the earliest branch, so selection is reproducible" do
    tied = [answering("Paris one."), answering("Paris two.")]
    selection = speculative.search(base, branches: tied)
    expect(answer_text(selection.best)).to eq("Paris one.")
  end

  it "refuses an empty beam -- there is nothing to select" do
    expect { speculative.search(base, branches: []) }.to raise_error(ArgumentError, /branch/)
  end
end
