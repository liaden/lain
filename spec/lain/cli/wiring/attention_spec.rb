# frozen_string_literal: true

RSpec.describe Lain::CLI::Wiring::Attention do
  let(:fed) { [] }
  let(:output) { StringIO.new }
  let(:switchboard) do
    mode_switch = Struct.new(:layers).new(Lain::Mode::LayerSet.new)
    Struct.new(:guard_inputs, :mode_switch).new(Struct.new(:secrets).new([]), mode_switch)
  end
  let(:paths) do
    home = Dir.mktmpdir
    Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(home, "state"), "HOME" => home })
  end
  let(:now) { [Time.at(1000)] }
  let(:clock) { class_double(Time).tap { |c| allow(c).to receive(:now) { now.first } } }
  let(:run_clock) { instance_double(Lain::RunClock, elapsed: 0.0) }
  let(:tracker) { Lain::AgentStates::Tracker.new(clock: run_clock) }
  let(:window) do
    Class.new do
      attr_reader :asked

      def focused? = (@asked = true) && false
    end.new
  end

  let(:done) do
    telemetry = Lain::Telemetry
    [telemetry::RequestSent.new(digest: "blake3:#{"e" * 64}", payload: {}, stream: true, extra: {},
                                prefix_digests: nil, prefix_chain_version: nil, requester: nil),
     telemetry::AskSettled.new(head: "blake3:#{"f" * 64}", stop_reason: "end_turn", turns: 1, seconds: 1.0)]
  end

  let(:herdr) { Struct.new(:focus, :notes).new(window, Lain::Sink::Null.new) }

  def attention(agent_states)
    allow(Lain::Notices).to receive(:for).and_return(->(*args) { fed << args })
    described_class.for(agent_states, switchboard, root: "/work/demo", paths:, env: {}, herdr:, clock:)
  end

  context "with no tracker" do
    it "keeps the notifier immediate and runs no notices" do
      subject = attention(nil)
      subject.notifier.bound_to(output).call("hello")

      expect([fed, output.string, subject.notices]).to eq([[%w[lain demo hello]], "\e]777;notify;demo;hello\a",
                                                           Lain::AgentStates::Notices::Never])
    end
  end

  context "with a tracker" do
    it "defers the notifier's sequence and feed entry" do
      attention(tracker).notifier.bound_to(output).call("hello")

      expect([fed, output.string]).to eq([[], ""])
    end

    it "names a failing feed on the herdr binding's notes" do
      attention(tracker).notifier

      expect(Lain::Notices).to have_received(:for).with(env: {}, notes: herdr.notes)
    end

    it "builds one notifier, shared with the notices" do
      subject = attention(tracker)

      expect(subject.notifier).to be(subject.notifier)
    end

    it "gives the notices the focus, asked when a notice falls due, and sends through the notifier" do
      subject = attention(tracker)
      notices = subject.notices
      subject.notifier.bound_to(output)
      done.each { tracker << _1 }
      now[0] += 31
      notices.tick

      expect([window.asked, fed]).to eq([true, [["lain", "demo", "done: main"]]])
    end
  end

  context "when the machine's notify-feed fails", :seam do
    it "says so once on the chat's own notes line" do
      bin = Dir.mktmpdir("lain-attention-bin")
      File.write(File.join(bin, "notify-feed"), "#!/bin/sh\nexit 1\n")
      File.chmod(0o755, File.join(bin, "notify-feed"))
      lines = []
      notes = Lain::Herdr::HeldNotes.new.bind(lines.method(:push))

      herdr = Struct.new(:focus, :notes).new(window, notes)
      notifier = described_class.for(nil, switchboard, root: "/work/demo", paths:, env: { "PATH" => bin }, herdr:)
                                .notifier.bound_to(output)
      2.times { notifier.call("hello") }

      expect(lines).to eq(["#{File.join(bin, "notify-feed")} exited 1"])
    ensure
      FileUtils.remove_entry(bin)
    end
  end
end
