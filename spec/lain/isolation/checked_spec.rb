# frozen_string_literal: true

RSpec.describe Lain::Isolation::Checked do
  let(:lease) { instance_double(Lain::Isolation::Lease, origin: Lain::Isolation::Lease::Origin.new) }
  let(:worker) { Lain::Isolation::SelfSync::Unaskable }
  let(:calls) { [] }
  let(:synced) { Lain::Isolation::SelfSync::Result.new(outcome: :synced) }

  def checks_answering(result)
    order = calls
    Class.new do
      define_method(:call) do |lease, worker:, worker_id:|
        order << [:checks, lease, worker, worker_id]
        result
      end
    end.new
  end

  def sync_answering(result)
    order = calls
    Class.new do
      define_method(:call) do |lease, worker:, worker_id:|
        order << [:sync, lease, worker, worker_id]
        result
      end
      define_method(:editorless) { |worker_env| worker_env.with(env: { "GIT_EDITOR" => "true" }) }
    end.new
  end

  def checks_result(outcome, detail: "") = Lain::Isolation::WorkerChecks::Result.new(outcome:, detail:)

  it "runs the checks before the self-sync, handing both the same lease, worker and worker id" do
    checked = described_class.new(checks: checks_answering(checks_result(:passed)), sync: sync_answering(synced))

    checked.call(lease, worker:, worker_id: "w-1")

    expect(calls).to eq([[:checks, lease, worker, "w-1"], [:sync, lease, worker, "w-1"]])
  end

  it "answers the sync's record with the checks merged into it" do
    checked = described_class.new(checks: checks_answering(checks_result(:passed)), sync: sync_answering(synced))

    record = checked.call(lease, worker:, worker_id: "w-1").to_record

    expect(record).to eq(synced.to_record.merge(checks: { outcome: :passed, attempts: [], detail: "" }))
  end

  it "adds the checks' failure to the sync's note, so the parent is told both" do
    dirty = Lain::Isolation::SelfSync::Result.new(outcome: :dirty, dirty: true, path: "/w")
    checked = described_class.new(checks: checks_answering(checks_result(:failed, detail: "rspec exited 1")),
                                  sync: sync_answering(dirty))

    note = checked.call(lease, worker:, worker_id: "w-1").note

    expect(note).to include(dirty.note).and include("checks failed: rspec exited 1")
  end

  it "owes the parent no note when the checks passed and the sync owes none" do
    checked = described_class.new(checks: checks_answering(checks_result(:passed)), sync: sync_answering(synced))

    expect(checked.call(lease, worker:, worker_id: "w-1").note).to eq("")
  end

  # A dispatch that did not return is torn down, not checked: nobody is
  # left to fix a red, and a teardown must not wait on the project's suite.
  it "passes an unasked sync to the inner sync alone, never running the checks" do
    inner = sync_answering(synced)
    order = calls
    found = synced
    inner.define_singleton_method(:unasked) do |lease, worker_id:|
      order << [:unasked, lease, worker_id]
      found
    end
    checked = described_class.new(checks: checks_answering(checks_result(:passed)), sync: inner)

    expect(checked.unasked(lease, worker_id: "w-1")).to be(synced)
    expect(calls).to eq([[:unasked, lease, "w-1"]])
  end

  it "keeps the sync's editorless environment" do
    env = Lain::WorkerEnv.new(cwd: "/w", env: {})
    checked = described_class.new(checks: checks_answering(checks_result(:passed)), sync: sync_answering(synced))

    expect(checked.editorless(env).env).to eq("GIT_EDITOR" => "true")
  end

  # Built the way the chat and the epic driver build it: from the project's
  # `isolation` table, over a real SelfSync.
  describe ".configured" do
    let(:base) { Lain::Isolation::WorkingBranch::NONE }

    def over(table)
      checks = described_class.configured(base:, layout: Lain::TestLayout::None,
                                          settings: Lain::Config::Isolation.from(table, path: nil))
      described_class.new(checks:, sync: Lain::Isolation::SelfSync.new(base:))
    end

    it "adds no checks field to the record when neither check nor lint is configured" do
      record = over({}).call(lease, worker:, worker_id: "w-1").to_record

      expect(record).to eq(Lain::Isolation::SelfSync::Result::NONE.to_record)
    end

    it "carries what the configured checks made of the lease onto the record" do
      record = over("lint" => ["rubocop"]).call(lease, worker:, worker_id: "w-1").to_record

      expect(record[:checks]).to include(outcome: :skipped, detail: Lain::Isolation::WorkerChecks::NO_CHECKOUT)
    end
  end
end
