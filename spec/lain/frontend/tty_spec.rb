# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Frontend::TTY do
  let(:channel) { Lain::Channel.new }
  let(:output) { StringIO.new }
  let(:input) { StringIO.new }
  let(:tty) { described_class.new(channel:, output:, input:) }

  def tool_output(tool_use_id: "tu_1", stream: :stdout, bytes: "hello\n")
    Lain::Telemetry::ToolOutput.new(tool_use_id:, stream:, bytes:)
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
end
