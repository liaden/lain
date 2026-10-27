# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Tripwire::Stops do
  subject(:stops) { described_class.new }

  let(:main) { Lain::Requester.main.name }
  let(:at) { Time.utc(2026, 10, 27, 12) }

  def everyone = [main, "researcher", "writer", "never_tripped"]

  it "stops and pauses nobody before a trip" do
    expect(everyone.map { [stops.stopped?(_1), stops.paused?(_1)] }).to all(eq([false, false]))
  end

  describe "a subagent's first trip" do
    it "stops that subagent and pauses main, and no one else" do
      expect(stops.trip("researcher", at:)).to eq(:stopped)

      expect(everyone.to_h { [_1, stops.stopped?(_1)] })
        .to eq(main => false, "researcher" => true, "writer" => false, "never_tripped" => false)
      expect(everyone.select { stops.paused?(_1) }).to eq([main])
    end

    it "remembers when it tripped" do
      stops.trip("researcher", at:)
      stops.trip("researcher", at: at + 60)

      expect([stops.tripped_at("researcher"), stops.tripped_at("writer")]).to eq([at, nil])
    end

    it "is not a second trip when the same subagent trips again" do
      stops.trip("researcher", at:)

      expect(stops.trip("researcher", at:)).to eq(:stopped)
      expect(stops.stopped?("writer")).to be(false)
    end
  end

  describe "a second trip" do
    it "by another subagent stops every requester, main included" do
      stops.trip("researcher", at:)

      expect(stops.trip("writer", at:)).to eq(:all_stopped)
      expect(everyone.map { stops.stopped?(_1) }).to all(be(true))
    end

    it "by main after a subagent stops every requester" do
      stops.trip("researcher", at:)

      expect(stops.trip(main, at:)).to eq(:all_stopped)
      expect(everyone.map { stops.stopped?(_1) }).to all(be(true))
    end

    it "leaves no one paused, since main is stopped" do
      stops.trip("researcher", at:)
      stops.trip("writer", at:)

      expect(everyone.select { stops.paused?(_1) }).to be_empty
    end
  end

  it "stops every requester at once when main trips first" do
    expect(stops.trip(main, at:)).to eq(:all_stopped)

    expect(everyone.map { stops.stopped?(_1) }).to all(be(true))
    expect(everyone.select { stops.paused?(_1) }).to be_empty
  end

  describe "a trip no record attributes" do
    let(:unknown) { Lain::Tripwire::Ledger::UNKNOWN }

    it "stops every requester at once, since it could be main" do
      expect(stops.trip(unknown, at:)).to eq(:all_stopped)
      expect(everyone.map { stops.stopped?(_1) }).to all(be(true))
    end

    it "stops every requester after a subagent's trip" do
      stops.trip("researcher", at:)

      expect(stops.trip(unknown, at:)).to eq(:all_stopped)
    end
  end

  it "takes no journal, so it can never write one under its own lock" do
    expect(described_class.instance_method(:initialize).parameters.map(&:last)).to eq([:main])
  end

  it "reads a Requester as its name" do
    expect(stops.trip(Lain::Requester.main, at:)).to eq(:all_stopped)
    expect(stops.stopped?(Lain::Requester.new(name: "researcher"))).to be(true)
  end

  describe "None, what a chat without the stop arm holds" do
    it "stops and pauses nobody" do
      expect(everyone.map { [described_class::None.stopped?(_1), described_class::None.paused?(_1)] })
        .to all(eq([false, false]))
    end
  end

  describe "STOPPING, the signals seeded to stop a requester" do
    it "leaves out the network signals and every weak signal" do
      expect(described_class::STOPPING).not_to include("refused_connect", "datagram_send", "judge_deny")
    end

    it "includes a refused exec" do
      expect(described_class::STOPPING).to include("refused_exec")
    end
  end

  # The Ledger trips inside the Journal's monitor while the tool phase asks Stops and then journals,
  # so Stops must never take the Journal under its own mutex.
  describe "shared between a ledger folding a journal and a reader journaling a refusal" do
    let(:journal) { Lain::Journal.new(io: StringIO.new) }
    let(:fence) { "/elsewhere/target/release/lain-fence" }

    def refused_exec_by(requester, id)
      journal << { "type" => "escalation", "tool" => "bash", "tool_use_id" => id, "requester" => requester,
                   "verdict" => "allow", "rung" => "rules", "reason" => "", "final" => false }
      journal << { "type" => "exec_record", "tool_use_id" => id, "profile" => "reader",
                   "execs" => [{ "path" => fence, "argv0" => "lain-fence", "rc" => 0 }],
                   "refusals" => [{ "path" => "/work/planted", "errno" => "EACCES" }], "fd_execs" => [],
                   "truncated" => false, "incomplete" => false, "connects" => [] }
    end

    it "cannot deadlock over 1,000 interleaved rounds" do
      journal.observe(Lain::Tripwire::Ledger.new(journal:, stops:))
      folding = Thread.new { 1_000.times { refused_exec_by("sub_#{_1}", "tu_#{_1}") } }
      asking = Thread.new do
        1_000.times do |n|
          journal << { "type" => "tool_refused", "requester" => "sub_#{n}", "stopped" => stops.stopped?("sub_#{n}") }
        end
      end

      expect([folding.join(5), asking.join(5)]).to all(be_a(Thread))
      expect(stops.stopped?(main)).to be(true)
    ensure
      [folding, asking].compact.each(&:kill)
    end
  end
end
