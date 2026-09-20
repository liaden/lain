# frozen_string_literal: true

RSpec.describe Lain::Epic::StageTransition do
  def stage_event(**overrides)
    described_class.new(epic_slug: "alpha", stage: "epic_plan", event: "started", **overrides)
  end

  it "journals under the underscored basename of its class" do
    expect(stage_event.journal_type).to eq("stage_transition")
    expect(described_class::JOURNAL_TYPE).to eq("stage_transition")
  end

  it "carries its epic, stage, and event into the record" do
    expect(stage_event.to_journal).to eq("type" => "stage_transition", "epic_slug" => "alpha",
                                         "stage" => "epic_plan", "event" => "started")
  end

  # A stage is a partition key, so a typo that constructed would fold onto a
  # partition nothing else writes to -- Stage's own closed set is what refuses it.
  it "refuses a stage outside the pipeline" do
    expect { stage_event(stage: "planning") }.to raise_error(Lain::Epic::UnknownStage, /planning/)
  end

  it "refuses an event outside started/completed" do
    expect { stage_event(event: "finished") }.to raise_error(ArgumentError, /event/)
  end

  it "accepts a Stage value as readily as its name" do
    expect(stage_event(stage: Lain::Epic::Stage.new("research")).stage).to eq("research")
  end

  it "is a deeply frozen, shareable value" do
    expect(stage_event).to be_deeply_frozen
  end
end
