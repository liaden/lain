# frozen_string_literal: true

require "json"
require "tmpdir"

RSpec.describe Lain::CLI::Resume::MismatchNotices do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  def session_with(arms:)
    header = Lain::SessionRecord.header(context: Lain::Context.new(model: "qwen3:4b", max_tokens: 64),
                                        toolset: Lain::Toolset.new, arms:, writer: CoreGraph::NO_WRITER)
    File.join(@dir, "session.ndjson").tap { |path| File.write(path, "#{JSON.generate(header)}\n") }
  end

  def notices(path, arms)
    described_class.new(path:).call(profile: Lain::CLI::RunProfile::UNRECORDED, model: nil, arms:)
  end

  def typed(**values) = Lain::CLI::Arms::UNSET.with(**values)

  def at_defaults(**arms) = { "confine" => "reader", "tripwire" => "observe", "round_budget" => "window" }.merge(arms)

  it "names a typed arm that differs from the recording" do
    path = session_with(arms: at_defaults)

    expect(notices(path, typed(confine: :off)))
      .to eq(["recorded with --confine reader; continuing with off (the current flags win)"])
  end

  it "says an arm the header did not record was recorded without it" do
    path = session_with(arms: at_defaults.except("confine"))

    expect(notices(path, typed(confine: :reader)))
      .to eq(["recorded without --confine (off); continuing with reader (the current flags win)"])
  end

  it "says what a fresh chat runs when an untyped arm keeps a recording weaker than the default" do
    path = session_with(arms: { "confine" => "classes" })

    expect(notices(path, typed))
      .to eq(["running with --confine classes, as recorded; a fresh chat runs reader " \
              "(pass --confine reader to run it)",
              "running without --tripwire (off), as recorded; a fresh chat runs observe " \
              "(pass --tripwire observe to run it)",
              "running without --round-budget (off), as recorded; a fresh chat runs window " \
              "(pass --round-budget window to run it)"])
  end

  it "stays silent when a typed arm agrees, or an untyped one keeps a recording at or above the default" do
    expect(notices(session_with(arms: at_defaults.except("confine")), typed(confine: :off))).to be_empty
    expect(notices(session_with(arms: at_defaults("judge_facts" => "facts")), typed)).to be_empty
  end

  describe "the compaction notice" do
    def session_compacting(compaction)
      header = Lain::SessionRecord.header(context: Lain::Context.new(model: "qwen3:4b", max_tokens: 64),
                                          toolset: Lain::Toolset.new, compaction:, writer: CoreGraph::NO_WRITER)
      File.join(@dir, "session.ndjson").tap { |path| File.write(path, "#{JSON.generate(header)}\n") }
    end

    def compaction_notices(path, typed)
      described_class.new(path:).call(profile: Lain::CLI::RunProfile::UNRECORDED, model: nil,
                                      compaction: Lain::CLI::CompactionProfile.typed(typed))
    end

    let(:off) { session_compacting({ "compact" => false, "compact_schedule" => "turn" }) }

    it "says an untyped run keeps a recording that ran without compaction" do
      expect(compaction_notices(off, {}))
        .to eq(["running without compaction, as recorded (pass --compact to compact)"])
    end

    it "names a typed --compact over it" do
      expect(compaction_notices(off, { compact: true }))
        .to eq(["recorded with --no-compact; continuing with --compact (the current flags win)"])
    end

    it "names a typed --no-compact over a recording that compacted" do
      expect(compaction_notices(session_compacting({ "compact_schedule" => "idle" }), { compact: false }))
        .to eq(["recorded with --compact; continuing with --no-compact (the current flags win)"])
    end

    it "stays silent for a recording that compacted" do
      expect(compaction_notices(session_compacting({ "compact_schedule" => "idle" }), {})).to be_empty
    end

    it "says nothing about compaction a caller did not pass" do
      expect(described_class.new(path: off).call(profile: Lain::CLI::RunProfile::UNRECORDED, model: nil))
        .to be_empty
    end
  end

  it "says nothing about arms a caller did not pass" do
    path = session_with(arms: {})

    expect(described_class.new(path:).call(profile: Lain::CLI::RunProfile::UNRECORDED, model: nil)).to be_empty
  end
end
