# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::GateParked do
  subject(:event) do
    described_class.new(artifact_digest: "blake3:abc", epic_slug: "alpha", issue_id: "a", stage: "implementation",
                        sha: "8b6b677", question: "Approve?")
  end

  it "journals as a gate_parked record carrying the whole address and the question" do
    expect(JSON.parse(JSON.generate(event.to_journal))).to eq(
      "type" => "gate_parked", "artifact_digest" => "blake3:abc", "epic_slug" => "alpha", "issue_id" => "a",
      "stage" => "implementation", "sha" => "8b6b677", "question" => "Approve?"
    )
  end

  it "accepts an epic-wide stage with no issue and no sha" do
    wide = described_class.new(artifact_digest: "blake3:abc", epic_slug: "alpha", issue_id: nil, stage: "research",
                               sha: nil, question: "Approve?")

    expect(wide).to have_attributes(issue_id: nil, sha: nil)
  end

  it "is deeply frozen when built from mutable input" do
    expect(described_class.new(artifact_digest: +"blake3:abc", epic_slug: +"alpha", issue_id: nil, stage: +"research",
                               sha: nil, question: +"Approve?")).to be_deeply_frozen
  end
end
