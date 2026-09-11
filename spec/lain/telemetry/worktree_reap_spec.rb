# frozen_string_literal: true

RSpec.describe Lain::Telemetry::WorktreeReap do
  it "journals what was reaped or kept, why, and the anchors that keep its work" do
    record = described_class.new(action: :kept, subject: :worktree, name: "/state/worktrees/abc/def",
                                 reason: "expired; its work is kept on anchors",
                                 anchors: ["refs/lain/worker/gc-def-0123456789ab"])

    expect(record.to_journal).to eq("type" => "worktree_reap", "action" => :kept, "subject" => :worktree,
                                    "name" => "/state/worktrees/abc/def",
                                    "reason" => "expired; its work is kept on anchors",
                                    "anchors" => ["refs/lain/worker/gc-def-0123456789ab"])
  end

  it "names no anchors by default" do
    expect(described_class.new(action: :reaped, subject: :anchor, name: "refs/lain/worker/w", reason: "landed")
                          .anchors).to eq([])
  end

  it "answers whether it reaped" do
    reaped = described_class.new(action: "reaped", subject: "branch", name: "refs/heads/epic/x", reason: "merged")

    expect([reaped.reaped?, reaped.action, reaped.subject]).to eq([true, :reaped, :branch])
  end

  it "refuses an action or a subject the reaper never reaches" do
    expect { described_class.new(action: :deleted, subject: :worktree, name: "/x", reason: "r") }
      .to raise_error(ArgumentError, /action/)
    expect { described_class.new(action: :kept, subject: :tag, name: "/x", reason: "r") }
      .to raise_error(ArgumentError, /subject/)
  end

  it "refuses a record that names nothing or gives no reason" do
    expect { described_class.new(action: :kept, subject: :worktree, name: "", reason: "r") }
      .to raise_error(ArgumentError, /name/)
    expect { described_class.new(action: :kept, subject: :worktree, name: "/x", reason: " ") }
      .to raise_error(ArgumentError, /reason/)
  end

  it "is deeply frozen, even from unfrozen strings" do
    record = described_class.new(action: :kept, subject: :worktree, name: +"/x", reason: +"r",
                                 anchors: [+"refs/lain/a"])

    expect(record).to be_deeply_frozen
  end
end
