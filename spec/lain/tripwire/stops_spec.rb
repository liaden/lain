# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Tripwire::Stops do
  subject(:stops) { described_class.new }

  let(:main) { Lain::Requester.main.name }

  def everyone = [main, "researcher", "writer", "never_tripped"]

  it "stops and pauses nobody before a trip" do
    expect(everyone.map { stops.standing(_1) }).to all(eq(:free))
  end

  describe "a subagent's first trip" do
    it "stops that subagent and pauses main, and no one else" do
      expect(stops.trip("researcher")).to eq(:stopped)

      expect(everyone.to_h { [_1, stops.standing(_1)] })
        .to eq(main => :paused, "researcher" => :stopped, "writer" => :free, "never_tripped" => :free)
    end

    it "names it as the first to trip, after others trip too" do
      stops.trip("researcher")
      stops.trip("writer")

      expect(stops.first_tripped).to eq("researcher")
    end

    it "is not a second trip when the same subagent trips again" do
      stops.trip("researcher")

      expect(stops.trip("researcher")).to eq(:stopped)
      expect(stops.standing("writer")).not_to eq(:stopped)
    end
  end

  describe "a second trip" do
    it "by another subagent stops every requester, main included" do
      stops.trip("researcher")

      expect(stops.trip("writer")).to eq(:all_stopped)
      expect(everyone.map { stops.standing(_1) }).to all(eq(:stopped))
    end

    it "by main after a subagent stops every requester" do
      stops.trip("researcher")

      expect(stops.trip(main)).to eq(:all_stopped)
      expect(everyone.map { stops.standing(_1) }).to all(eq(:stopped))
    end

    it "leaves no one paused, since main is stopped" do
      stops.trip("researcher")
      stops.trip("writer")

      expect(everyone.map { stops.standing(_1) }).not_to include(:paused)
    end
  end

  it "stops every requester at once when main trips first" do
    expect(stops.trip(main)).to eq(:all_stopped)

    expect(everyone.map { stops.standing(_1) }).to all(eq(:stopped))
    expect(everyone.map { stops.standing(_1) }).not_to include(:paused)
  end

  describe "a trip no record attributes" do
    let(:unknown) { Lain::Tripwire::Ledger::UNKNOWN }

    it "stops every requester at once, since it could be main" do
      expect(stops.trip(unknown)).to eq(:all_stopped)
      expect(everyone.map { stops.standing(_1) }).to all(eq(:stopped))
    end

    it "stops every requester after a subagent's trip" do
      stops.trip("researcher")

      expect(stops.trip(unknown)).to eq(:all_stopped)
    end
  end

  # Every unnamed spawn shares this name, so a second unnamed trip would read as the first one again.
  it "stops every requester when an unnamed subagent trips, since the name is not one agent's" do
    unnamed = Lain::Requester::UNNAMED

    expect(stops.trip(unnamed)).to eq(:all_stopped)
    expect(everyone.map { stops.standing(_1) }).to all(eq(:stopped))
  end

  describe "#standing, one read of where a requester stands" do
    it "answers free for everyone before a trip" do
      expect(everyone.map { stops.standing(_1) }).to all(eq(:free))
    end

    it "answers stopped for the subagent that tripped, paused for main and free for the rest" do
      stops.trip("researcher")

      expect(everyone.to_h { [_1, stops.standing(_1)] })
        .to eq(main => :paused, "researcher" => :stopped, "writer" => :free, "never_tripped" => :free)
    end

    it "answers stopped for everyone after a second trip" do
      stops.trip("researcher")
      stops.trip("writer")

      expect(everyone.map { stops.standing(_1) }).to all(eq(:stopped))
    end
  end

  it "takes no journal, so it can never write one under its own lock" do
    expect(described_class.instance_method(:initialize).parameters.map(&:last)).to eq([:main])
  end

  it "reads a Requester as its name" do
    expect(stops.trip(Lain::Requester.main)).to eq(:all_stopped)
    expect(stops.standing(Lain::Requester.new(name: "researcher"))).to eq(:stopped)
  end

  describe "None, what a chat without the stop arm holds" do
    it "answers only standing, first_tripped and stopping" do
      expect(%i[stopped? paused? tripped_at].select { described_class::None.respond_to?(_1) }).to be_empty
    end

    it "settles nothing, so a hard stop crossed trips no one" do
      expect(described_class::None.stopping(rules: Lain::Tripwire::Rules::DEFAULT))
        .to equal(Lain::Tripwire::Ledger::Stopping::Off)
    end

    it "stands everyone free" do
      expect(everyone.map { described_class::None.standing(_1) }).to all(eq(:free))
    end

    it "names nobody as the first to trip" do
      expect(described_class::None.first_tripped).to be_nil
    end
  end

  describe "#stopping, the ledger's half of the stop" do
    it "is a real Stopping over these stops, which trips them on a settled crossing" do
      stopping = stops.stopping(rules: Lain::Tripwire::Rules::DEFAULT)
      crossing = Lain::Tripwire::Ledger::Stopping::Crossing.new(requester: "researcher", signal: "refused_exec",
                                                                trips: true, unseeded: [])

      stopping.settle(crossing)

      expect(stops.standing("researcher")).to eq(:stopped)
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
          journal << { "type" => "tool_refused", "requester" => "sub_#{n}",
                       "stopped" => stops.standing("sub_#{n}") == :stopped }
        end
      end

      expect([folding.join(5), asking.join(5)]).to all(be_a(Thread))
      expect(stops.standing(main)).to eq(:stopped)
    ensure
      [folding, asking].compact.each(&:kill)
    end
  end
end
