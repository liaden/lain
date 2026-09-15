# frozen_string_literal: true

require "json"
require "stringio"

# {Telemetry::Journalable} is included at 62 sites and its contract was pinned at 7 of
# them. The uniqueness example below is the one no per-class spec can write: journal_type
# is the class's SHORT name, so `Foo::Result` beside an existing `Bar::Result` gives both
# the same discriminator, and recorded journals replay against that string.
RSpec.describe Lain::Telemetry::Journalable do
  includers = ObjectSpace.each_object(Class).select do |klass|
    klass.include?(described_class)
  rescue StandardError
    false
  end.sort_by(&:name)

  built, unreached = GenericBuild.partition(includers.select { |klass| klass < Data })

  it "is included by a registry the sweep actually found" do
    expect(includers.size).to be > 50
    # Named, not skipped: the constructors no generic dummy satisfies are this
    # sweep's blind spot, and it is reviewable.
    expect(unreached.map(&:name)).to all(start_with("Lain::"))
  end

  it "gives every record a discriminator no other record answers to" do
    collisions = built.group_by { |_, record| record.journal_type }
                      .select { |_, pairs| pairs.size > 1 }
                      .transform_values { |pairs| pairs.map { |klass, _| klass.name } }

    expect(collisions).to be_empty
  end

  # Against #journal_type, not against the basename: Forge::Intent and Forge::Outcome
  # deliberately override it, for the reason the example above tests.
  it "tags every record with its own type, under String keys only" do
    wrong = built.reject do |_, record|
      journal = record.to_journal
      journal["type"] == record.journal_type && journal.keys.all?(String)
    end

    expect(wrong.map(&:first)).to be_empty
  end

  # A torn line cannot be parsed, so the sign-off folds decide whether to refuse
  # one by reading its type off the prefix the Journal writes. That rests on
  # `ts` then `type` leading the line -- a convention with two sources, pinned
  # here: the Journal stamps `ts` ahead of whatever an entry carries, and
  # Journalable puts `type` first. The sweep below covers the records
  # GenericBuild can construct; the two a sign-off rests on refuse every dummy,
  # so they are built by hand.
  describe "the record prefix a torn line is sniffed by" do
    def written(entry)
      io = StringIO.new
      Lain::Journal.new(io:, clock: -> { "2026-07-28T09:00:00.000000Z" }).record(entry)
      io.string
    end

    def sniffed(entry) = Lain::CLI::SessionJournals::Torn.sniff(written(entry))

    it "is stamped by the Journal with ts first, ahead of an entry's own ts" do
      line = written({ "type" => "raw", "ts" => "entry's own", "x" => 1 })

      expect(JSON.parse(line).keys.first(2)).to eq(%w[ts type])
    end

    it "leads every Journalable's own serialisation with type" do
      expect(built.reject { |_, record| record.to_journal.keys.first == "type" }.map(&:first)).to be_empty
    end

    it "reads back the type of every record the sweep could build, through the real Journal" do
      expect(built.reject { |_, record| sniffed(record) == record.journal_type }.map(&:first)).to be_empty
    end

    it "reads back a GateDecision and a StageTransition, the records a sign-off rests on" do
      decision = Lain::Approval::GateDecision.new(artifact_digest: "blake3:plan", epic_slug: "alpha",
                                                  stage: "research", approved: false, answered_by: "deferred",
                                                  policy: "deferred", latency: 0.1)
      transition = Lain::Epic::StageTransition.new(epic_slug: "alpha", stage: "research", event: "started")

      expect([sniffed(decision), sniffed(transition)]).to eq(%w[gate_decision stage_transition])
    end
  end

  it "journals only what NDJSON can carry, so no line can fail to parse" do
    unserializable = built.reject do |_, record|
      JSON.parse(JSON.generate(record.to_journal))
      true
    rescue StandardError
      false
    end

    expect(unserializable.map(&:first)).to be_empty
  end
end
