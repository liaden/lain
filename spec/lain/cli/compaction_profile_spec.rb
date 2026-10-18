# frozen_string_literal: true

RSpec.describe Lain::CLI::CompactionProfile do
  describe ".typed" do
    it "reads each compaction flag, nil for one not typed" do
      typed = described_class.typed({ compact_keep: 8, compact_strategy: "elide" })

      expect(typed).to have_attributes(keep: 8, strategy: "elide", bytes: nil, cap: nil, fallback: nil)
    end

    it "reads the schedule flag" do
      expect(described_class.typed({ compact_schedule: "turn" })).to have_attributes(schedule: "turn")
    end

    it "is entirely unset for the options a chat with no compaction flag parses to" do
      expect(described_class.typed({ compact: true })).to eq(described_class::UNSET)
    end
  end

  it "is deeply frozen, so it stays shareable" do
    expect(described_class.typed({ compact_strategy: +"elide", compact_fallback: +"none",
                                   compact_schedule: +"idle" })).to be_deeply_frozen
  end

  describe ".from_header" do
    it "reads the keys a header records" do
      recorded = described_class.from_header({ "compact_strategy" => "elide", "compact_keep" => 4,
                                               "compact_fallback" => "none" })

      expect(recorded).to have_attributes(strategy: "elide", keep: 4, fallback: "none", bytes: nil, cap: nil)
    end

    it "reads a recorded schedule" do
      expect(described_class.from_header({ "compact_schedule" => "idle" })).to have_attributes(schedule: "idle")
    end

    it "invents no schedule a header does not record" do
      expect(described_class.from_header({ "provider" => "ollama" })).to have_attributes(schedule: nil)
    end

    it "is unset for no header at all" do
      expect(described_class.from_header({})).to eq(described_class::UNSET)
    end
  end

  describe "#over" do
    let(:recorded) { described_class.from_header({ "compact_strategy" => "elide", "compact_keep" => 4 }) }

    it "takes the recorded value for a field nobody typed" do
      expect(described_class::UNSET.over(recorded)).to eq(recorded)
    end

    it "lets a typed field win over the recorded one, field by field" do
      resolved = described_class.typed({ compact_keep: 8 }).over(recorded)

      expect(resolved).to have_attributes(keep: 8, strategy: "elide")
    end
  end

  describe "#to_header" do
    it "carries only the fields that are set" do
      expect(described_class.typed({ compact_keep: 8 }).to_header).to eq("compact_keep" => 8)
    end

    it "is empty when nothing is set" do
      expect(described_class::UNSET.to_header).to eq({})
    end
  end

  describe "#schedule_or_default" do
    it "is the typed schedule, else the recorded one, else the default" do
      recorded = described_class.from_header({ "compact_schedule" => "idle" })

      expect(described_class.typed({ compact_schedule: "turn" }).over(recorded).schedule_or_default).to eq("turn")
      expect(described_class::UNSET.over(recorded).schedule_or_default).to eq("idle")
      expect(described_class::UNSET.schedule_or_default).to eq("idle")
    end

    it "defaults to a member of SCHEDULES" do
      expect(described_class::SCHEDULES).to include(described_class::DEFAULT_SCHEDULE)
    end
  end

  describe "#to_options" do
    it "spells the set fields as the flags Backend reads" do
      expect(described_class.typed({ compact_cap: 9, compact_strategy: "elide" }).to_options)
        .to eq(compact_cap: 9, compact_strategy: "elide")
    end
  end
end
