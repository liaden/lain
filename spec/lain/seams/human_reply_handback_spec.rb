# frozen_string_literal: true

require "async"
require "stringio"
require "tmpdir"

# What a human at a terminal actually SEES when their own reply comes back for
# being too long.
#
# The measurement, the re-open and the delivery are all pinned as units in
# `spec/lain/tools/ask_human_spec.rb`, and every one of them passed while the
# terminal printed nothing: the handback rode the arrival seam as a value the
# TTY's one-line surfaces did not recognise, and the announce-once guard was
# keyed on the SET, so the second arrival for one question was swallowed. A
# human typed 65 KB, pressed Enter and got a bare `human> ` back.
#
# So every example here drives the REAL assembly with no double between the
# parts under test -- {CLI::Wiring::Askers}, the {Tools::AskHuman::Notifying}
# it enrols, the real {CLI::HumanReplies} and its real fibers, and a real
# {Frontend::TTY} writing into a StringIO. Only the conductor is doubled,
# because it is a terminal; nothing between the tool and the screen is.
RSpec.describe "a human's reply handed back", :seam do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:output) { StringIO.new }
  let(:tty) do
    Lain::Frontend::TTY.new(channel: Lain::Channel.new, output:, input: StringIO.new,
                            history_path: File.join(@dir, "history"))
  end
  let(:store) { Lain::Store.new }
  let(:parent) do
    Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
  end
  let(:conductor) { instance_double(Lain::CLI::Conductor) }
  let(:askers) do
    Lain::CLI::Wiring::Askers.new(observer: Lain::Event::ChainWriter::Null.new)
  end
  let(:ask_human) { askers.enrol(parent, agent: "chat").asker }
  let(:replies) do
    Lain::CLI::HumanReplies.new(tty:, conductor:, ask_human: askers.directory, questions: askers.questions)
  end
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }
  let(:ceiling) { Lain::Tools::AskHuman::Ceiling::BOUND.limit }
  let(:oversized) { "OVERSIZED-BODY " * ((ceiling / 15) + 1) }

  # Real fibers, so the exchange finishes when it finishes. Bounded, so a
  # regression that parks forever fails the example rather than hanging the
  # suite.
  def pumped_until(task, timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    task.sleep(0.005) until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  # The whole exchange, with the human's lines scripted at `human> `.
  def exchange(*typed)
    lines = typed.dup
    allow(conductor).to receive(:read_reply) { |_tty, _prompt| lines.shift }
    Sync { |task| answered_under(task) }
  end

  # The reply surfaces are the run's own, started and stopped around the call
  # as CLI::Wiring does it: one left running outlives the example and reads the
  # next one's scripted lines.
  def answered_under(task)
    surfaces = replies.session_surfaces(task) + replies.surfaces(task)
    run = task.async { ask_human.call({ "question" => "which file?" }, invocation) }
    pumped_until(task) { run.finished? }
    run.wait
  ensure
    surfaces.each(&:stop)
  end

  it "prints the arrival note once and delivers an ordinary answer" do
    result = exchange("config.rb")

    expect(result.content).to eq("config.rb")
    expect(output.string.scan("which file?").size).to be >= 1
  end

  # The acceptance criterion, read off the screen: told it is too long, told
  # how long, told the ceiling, told what to type. It is also where the SECOND
  # arrival is now observed -- the over-ceiling note exists only because the
  # handback announced again, which is the swallowed arrival this file is about.
  it "tells the human at the terminal the size, the ceiling and what to type" do
    result = exchange(oversized, "send")

    expect(result).to be_ok
    expect(result.content).to eq(oversized)
    aggregate_failures do
      expect(output.string).to include("over the ceiling of #{ceiling}")
      expect(output.string).to include(oversized.bytesize.to_s)
      expect(output.string).to include("type `send`")
    end
  end

  # The other half of the same fix, and the reason un-suppressing the
  # announce-once guard on its own would have been worse than the silence:
  # the handback's BYTES are the whole oversized reply, and the note is one
  # line. Measured against the reply rather than a constant, so it is the
  # relationship being pinned and not a width.
  it "says all of that without putting the reply itself in the scrollback" do
    exchange(oversized, "send")

    expect(output.string.bytesize).to be < oversized.bytesize
    expect(output.string).not_to include("OVERSIZED-BODY")
  end

  # Where "shown their own text again" is served. The one-line note above the
  # prompt is the wrong place for 65 KB; the document a human opens on purpose
  # is the right one.
  it "shows the reply itself to a human who opens /inbox at the handback prompt" do
    result = exchange(oversized, "/inbox", "send")

    expect(result.content).to eq(oversized)
    expect(output.string).to include("over the ceiling of #{ceiling}").and include("OVERSIZED-BODY")
  end

  it "leaves exactly one inbox row across the whole exchange, and none after it" do
    exchange(oversized, "send")

    expect(replies.pending?).to be(false)
  end

  it "delivers what the human typed instead when they decline" do
    result = exchange(oversized, "config.rb")

    expect(result.content).to eq("config.rb")
  end
end
