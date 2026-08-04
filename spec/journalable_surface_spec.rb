# frozen_string_literal: true

require "json"

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
