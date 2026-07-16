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
end
