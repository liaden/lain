# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe Lain::Frontend::TTY do
  let(:channel) { Lain::Channel.new }
  let(:output) { StringIO.new }
  let(:input) { StringIO.new }
  let(:tty) { described_class.new(channel:, output:, input:) }

  def tool_output(tool_use_id: "tu_1", stream: :stdout, bytes: "hello\n")
    Lain::Telemetry::ToolOutput.new(tool_use_id:, stream:, bytes:)
  end

  # Reline::HISTORY is process-global (Reline::History < Array), so every example
  # that touches it must restore the pre-existing content -- otherwise a line
  # pushed by one example leaks into the next.
  around do |example|
    original = Reline::HISTORY.to_a
    Reline::HISTORY.clear
    example.run
    Reline::HISTORY.clear
    Reline::HISTORY.concat(original)
  end

  # A double standing in for a real terminal's input: #prompt only takes the
  # reline/history path when `input.tty?` is true, which StringIO never is.
  def tty_input
    instance_double(IO, tty?: true)
  end

  describe "#drain_and_render" do
    it "renders every currently-queued event and returns how many it rendered" do
      channel.push(tool_output(bytes: "first\n"))
      channel.push(tool_output(bytes: "second\n"))

      expect(tty.drain_and_render).to eq(2)
      expect(output.string).to include("first").and include("second")
    end

    it "attributes rendered output by tool_use_id and stream" do
      channel.push(tool_output(tool_use_id: "tu_abc", stream: :stderr, bytes: "boom\n"))

      tty.drain_and_render

      expect(output.string).to include("tu_abc").and include("stderr").and include("boom")
    end

    it "does not block and renders nothing when the channel is empty" do
      expect(tty.drain_and_render).to eq(0)
      expect(output.string).to eq("")
    end
  end

  describe "#run" do
    it "enters the alternate screen before yielding and restores it after" do
      tty.run { channel.close }

      expect(output.string).to start_with(described_class::ALTERNATE_SCREEN_ON)
      expect(output.string).to end_with(described_class::ALTERNATE_SCREEN_OFF)
    end

    it "restores the main screen even when the yielded block raises" do
      expect { tty.run { raise "boom" } }.to raise_error("boom")

      expect(output.string).to end_with(described_class::ALTERNATE_SCREEN_OFF)
    end

    it "drains and renders events pushed before the block closes the channel" do
      channel.push(tool_output(bytes: "streamed live\n"))

      tty.run { channel.close }

      expect(output.string).to include("streamed live")
    end

    it "renders its ToolOutput events, ignores unrelated events, and exits on close" do
      channel.push(tool_output(bytes: "mine\n"))
      channel.push(Lain::Telemetry::Dropped.new(count: 3))

      tty.run { channel.close }

      expect(output.string).to include("mine")
    end

    it "yields self, so a caller can drive #prompt / #render_response inside the block" do
      yielded = nil
      tty.run do |handle|
        yielded = handle
        channel.close
      end

      expect(yielded).to be(tty)
    end

    it "closes the channel on the way out even if the block does not" do
      tty.run { :noop }

      expect(channel).to be_closed
    end
  end

  describe "#prompt" do
    it "reads a chomped line from a non-tty input" do
      input.string = "hello there\n"

      expect(tty.prompt).to eq("hello there")
    end

    it "returns nil at EOF" do
      expect(tty.prompt).to be_nil
    end

    it "writes the prompt text to output before reading" do
      input.string = "x\n"

      tty.prompt("> ")

      expect(output.string).to include(">")
    end
  end

  describe "history (XDG state, T12)" do
    around do |example|
      Dir.mktmpdir { |dir| @history_dir = dir and example.run }
    end

    def history_path
      File.join(@history_dir, "history")
    end

    def tty_with_history(history_path: self.history_path, input: tty_input)
      described_class.new(channel:, output:, input:, history_path:)
    end

    it "loads an existing history file into Reline::HISTORY, in order, when TTY starts" do
      File.write(history_path, "first command\nsecond command\n")

      tty_with_history.run { channel.close }

      expect(Reline::HISTORY.to_a).to eq(["first command", "second command"])
    end

    it "writes an accepted line to disk before the next prompt" do
      allow(Reline).to receive(:readline).and_return("remember me")

      tty_with_history.prompt

      expect(File.read(history_path)).to eq("remember me\n")
    end

    it "creates the history file owner-only (0600) at open(), with no chmod window" do
      allow(Reline).to receive(:readline).and_return("secret-adjacent line")
      expect(File).not_to receive(:chmod)

      tty_with_history.prompt

      expect(File.stat(history_path).mode & 0o777).to eq(0o600)
    end

    it "appends rather than truncating across multiple accepted lines" do
      allow(Reline).to receive(:readline).and_return("one", "two")

      history_tty = tty_with_history
      2.times { history_tty.prompt }

      expect(File.read(history_path)).to eq("one\ntwo\n")
    end

    it "never creates the history file for non-tty input" do
      allow(input).to receive(:tty?).and_return(false)
      input.string = "plain line\n"

      described_class.new(channel:, output:, input:, history_path:).prompt

      expect(File.exist?(history_path)).to be(false)
    end

    it "degrades loudly-but-usable when the history location is unwritable" do
      blocking_file = File.join(@history_dir, "blocked")
      File.write(blocking_file, "not a directory")
      unwritable_path = File.join(blocking_file, "history")
      allow(Reline).to receive(:readline).and_return("still works")

      line = nil
      expect { line = tty_with_history(history_path: unwritable_path).prompt }.not_to raise_error

      expect(line).to eq("still works")
      expect(output.string.downcase).to include("warning")
    end

    it "renders exactly one warning even after repeated failed writes" do
      blocking_file = File.join(@history_dir, "blocked")
      File.write(blocking_file, "not a directory")
      unwritable_path = File.join(blocking_file, "history")
      allow(Reline).to receive(:readline).and_return("a", "b")

      history_tty = tty_with_history(history_path: unwritable_path)
      2.times { history_tty.prompt }

      expect(output.string.downcase.scan("warning").size).to eq(1)
    end
  end

  describe "#render_response" do
    it "prints the response's text" do
      response = Lain::Response.new(
        content: [{ "type" => "text", "text" => "the answer is 4" }],
        stop_reason: :end_turn
      )

      tty.render_response(response)

      expect(output.string).to include("the answer is 4")
    end
  end

  describe "#render_error" do
    it "prints the message" do
      tty.render_error("something broke")

      expect(output.string).to include("something broke")
    end
  end

  # OM-4: a pending ask_human question is surfaced synchronously so the human
  # sees what they are answering before #prompt reads the reply -- like
  # #render_response, it bypasses the Channel (a finished exchange, not a
  # concurrently-arriving stream).
  describe "#render_question" do
    it "prints the question the agent put to the human" do
      tty.render_question("which config file should I edit?")

      expect(output.string).to include("which config file should I edit?")
    end
  end

  # T21: the countdown status line, ticked externally (a real caller is a
  # timer thread; these specs drive it directly with an injected clock so no
  # example needs a real sleep).
  describe "#render_countdown" do
    let(:coordinator) { instance_double(Lain::CLI::Shutdown, signal: nil) }

    # A plain incrementing lambda stands in for the monotonic clock -- one
    # call per tick, exactly what #render_countdown makes, so N calls to
    # render_countdown advance "now" by N steps with no real time passing.
    def counting_clock(start:, step: 1)
      now = start
      lambda do
        value = now
        now += step
        value
      end
    end

    # Both output and input must present as a real terminal for the
    # interactive (escape-drawing, key-reading) path -- StringIO's #tty? is
    # always false, so these examples stub it on rather than swap the double
    # type, matching the existing `allow(input).to receive(:tty?)` idiom
    # above.
    def interactive_tty(clock: counting_clock(start: 100))
      allow(output).to receive(:tty?).and_return(true)
      allow(input).to receive(:tty?).and_return(true)
      described_class.new(channel:, output:, input:, pastel: Pastel.new(enabled: false), clock:)
    end

    def seconds_rendered
      output.string.scan(/closing in (\d+)s/).flatten.map(&:to_i)
    end

    it "renders three successive ticks with decreasing seconds and the offered keys" do
      tty = interactive_tty

      3.times { tty.render_countdown(deadline: 103, options: { coordinator: }) }

      expect(seconds_rendered).to eq([3, 2, 1])
      expect(output.string).to include("[c] cancel")
      expect(output.string).to include("[w] wait longer")
      expect(output.string).to include("[r] respond then exit")
    end

    it "forwards a pressed offered key to the coordinator as a signal" do
      input.string = "w"
      tty = interactive_tty

      tty.render_countdown(deadline: 103, options: { coordinator: })

      expect(coordinator).to have_received(:signal).with(:extend)
    end

    it "ignores a key that is not one of the offered bindings" do
      input.string = "z"
      tty = interactive_tty

      tty.render_countdown(deadline: 103, options: { coordinator: })

      expect(coordinator).not_to have_received(:signal)
    end

    it "renders a grown deadline on the tick after the coordinator re-arms the window" do
      tty = interactive_tty

      tty.render_countdown(deadline: 103, options: { coordinator: })
      tty.render_countdown(deadline: 163, options: { coordinator: })

      expect(seconds_rendered.last).to be > seconds_rendered.first
    end

    it "clears and redraws the countdown line around a channel event so the two never interleave" do
      tty = interactive_tty
      tty.render_countdown(deadline: 103, options: { coordinator: })
      before_event = output.string.length

      channel.push(tool_output(bytes: "live output\n"))
      tty.drain_and_render

      full = output.string
      event_index = full.index("live output")
      clear_index = full.index(TTY::Cursor.clear_line, before_event)

      expect(event_index).not_to be_nil
      expect(clear_index).to be < event_index
      expect(full.index("closing in", event_index)).not_to be_nil, "expected the countdown to redraw after the event"
    end

    it "degrades to a plain line with no key reading and no escapes when output is not a tty" do
      allow(input).to receive(:tty?).and_return(true)
      input.string = "w"
      plain_tty = described_class.new(channel:, output:, input:, clock: counting_clock(start: 100))

      plain_tty.render_countdown(deadline: 103, options: { coordinator: })

      expect(output.string).not_to match(/\e\[/)
      expect(output.string).to include("closing in 3s")
      expect(coordinator).not_to have_received(:signal)
    end

    it "degrades the same way when input is not a tty, even on a tty output" do
      allow(output).to receive(:tty?).and_return(true)
      input.string = "w"
      plain_tty = described_class.new(channel:, output:, input:, clock: counting_clock(start: 100))

      plain_tty.render_countdown(deadline: 103, options: { coordinator: })

      expect(output.string).not_to match(/\e\[/)
      expect(output.string).to include("closing in 3s")
      expect(coordinator).not_to have_received(:signal)
    end
  end

  # The window-scoped lifecycle (T21 fix round): a countdown that has ended
  # must leave no trace -- later channel events take the plain pre-T21 path,
  # and the terminal mode entered at window start is restored exactly once.
  describe "#stop_countdown" do
    let(:coordinator) { instance_double(Lain::CLI::Shutdown, signal: nil) }

    def counting_clock(start:, step: 1)
      now = start
      lambda do
        value = now
        now += step
        value
      end
    end

    def interactive_tty(input: self.input, clock: counting_clock(start: 100))
      allow(output).to receive(:tty?).and_return(true)
      allow(input).to receive(:tty?).and_return(true) if input.equal?(self.input)
      described_class.new(channel:, output:, input:, pastel: Pastel.new(enabled: false), clock:)
    end

    # The Evans-blocker seam: a console-capable input the spec can spy on.
    # StringIO cannot see termios, so the raw-once/restore-once contract is
    # pinned against the io/console duck (`raw!`/`console_mode`); the PTY
    # probe in the handback is the evidence for the real-terminal half.
    def console_input(saved_mode: :cooked_mode)
      instance_double(IO, tty?: true, raw!: nil, console_mode: saved_mode, :console_mode= => nil).tap do |console|
        allow(console).to receive(:read_nonblock).and_raise(IO::EAGAINWaitReadable)
      end
    end

    it "returns later channel events to the plain path, with no stale status line redrawn" do
      tty = interactive_tty
      2.times { tty.render_countdown(deadline: 103, options: { coordinator: }) }

      tty.stop_countdown
      after_stop = output.string.length
      channel.push(tool_output(bytes: "long after the window\n"))
      tty.drain_and_render

      tail = output.string[after_stop..]
      expect(tail).not_to include("closing in")
      expect(tail).not_to match(/\e\[/)
      expect(tail).to include("long after the window\n")
    end

    it "erases the bottom status line rather than leaving it on screen" do
      tty = interactive_tty
      tty.render_countdown(deadline: 103, options: { coordinator: })
      before_stop = output.string.length

      tty.stop_countdown

      expect(output.string[before_stop..]).to include(TTY::Cursor.clear_line)
    end

    it "is idempotent: a second stop writes nothing and restores nothing again" do
      console = console_input
      tty = interactive_tty(input: console)
      tty.render_countdown(deadline: 103, options: { coordinator: })
      tty.stop_countdown
      after_first = output.string.length

      tty.stop_countdown

      expect(output.string.length).to eq(after_first)
      expect(console).to have_received(:console_mode=).once
    end

    it "enters raw mode once for the whole window, not once per tick" do
      console = console_input
      tty = interactive_tty(input: console)

      3.times { tty.render_countdown(deadline: 103, options: { coordinator: }) }

      expect(console).to have_received(:raw!).once
    end

    it "restores the console mode it saved at window start" do
      console = console_input(saved_mode: :the_mode_before)
      tty = interactive_tty(input: console)
      tty.render_countdown(deadline: 103, options: { coordinator: })

      tty.stop_countdown

      expect(console).to have_received(:console_mode=).with(:the_mode_before).once
    end

    it "never leaves the terminal raw when the run block raises mid-window" do
      console = console_input
      tty = interactive_tty(input: console)

      expect do
        tty.run do
          tty.render_countdown(deadline: 103, options: { coordinator: })
          raise "boom"
        end
      end.to raise_error("boom")

      expect(console).to have_received(:console_mode=).once
    end

    it "does not enter raw mode at all for a plain (non-interactive) countdown" do
      console = console_input
      allow(console).to receive(:tty?).and_return(false)
      tty = interactive_tty(input: console)

      tty.render_countdown(deadline: 103, options: { coordinator: })
      tty.stop_countdown

      expect(console).not_to have_received(:raw!)
      expect(console).not_to have_received(:console_mode=)
    end
  end
end
