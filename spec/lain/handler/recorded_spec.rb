# frozen_string_literal: true

RSpec.describe Lain::Handler::Recorded do
  def tool_call(id, name = "read_file", input = {})
    Lain::Effect::ToolCall.new(tool_use_id: id, name: name, input: input)
  end

  let(:recorded_ok) { Lain::Tool::Result.ok("recorded output") }

  describe "replay" do
    subject(:handler) { described_class.new(outcomes: { "call-1" => recorded_ok }) }

    it "returns the recorded outcome for a recorded id, performing nothing" do
      expect(handler.call(tool_call("call-1"))).to eq(recorded_ok)
    end

    it "keys on tool_use_id, not tool name" do
      # Same tool name, different call id -> not this recording.
      expect(handler.handles?(tool_call("call-2"))).to be(false)
    end
  end

  describe "a replay miss" do
    it "falls through to inner when composed in front of another handler" do
      live_answer = Lain::Tool::Result.ok("live output")
      inner = Lain::Handler::Mock.new(default: live_answer)
      handler = described_class.new(outcomes: { "call-1" => recorded_ok }, inner: inner)

      expect(handler.call(tool_call("call-1"))).to eq(recorded_ok)
      expect(handler.call(tool_call("unrecorded"))).to eq(live_answer)
    end

    it "never invents a success: with no inner, an unrecorded call raises" do
      handler = described_class.new(outcomes: { "call-1" => recorded_ok })
      expect { handler.call(tool_call("unrecorded")) }
        .to raise_error(Lain::Handler::UnhandledEffect)
    end
  end

  describe "an Approval wrapper on replay" do
    subject(:handler) { described_class.new(outcomes: { "call-1" => recorded_ok }) }

    # On replay the recorded outcome already reflects whatever approval decided;
    # no gate is re-run, the wrapper simply unwraps to the recorded result.
    it "replays the recorded result without any approval policy" do
      approval = Lain::Effect::Approval.new(effect: tool_call("call-1"))
      expect(handler.call(approval)).to eq(recorded_ok)
    end

    it "does not handle an Approval whose inner call is unrecorded" do
      approval = Lain::Effect::Approval.new(effect: tool_call("nope"))
      expect(handler.handles?(approval)).to be(false)
    end
  end

  describe "construction" do
    it "stringifies outcome keys so a Symbol id matches a String id" do
      handler = described_class.new(outcomes: { recorded_call: recorded_ok })
      expect(handler.call(tool_call("recorded_call"))).to eq(recorded_ok)
    end

    it "rejects a non-Result outcome loudly" do
      expect { described_class.new(outcomes: { "x" => "not a result" }) }
        .to raise_error(ArgumentError)
    end
  end

  describe ".from_journal" do
    it "reconstitutes outcomes from journaled tool_result records (Hashes)" do
      records = [
        { "type" => "tool_result", "tool_use_id" => "call-1", "content" => "ok text", "is_error" => false },
        { "type" => "tool_result", "tool_use_id" => "call-2", "content" => "boom", "is_error" => true },
        { "type" => "turn", "digest" => "abc" } # ignored
      ]
      handler = described_class.from_journal(records)

      expect(handler.call(tool_call("call-1"))).to eq(Lain::Tool::Result.ok("ok text"))
      expect(handler.call(tool_call("call-2"))).to eq(Lain::Tool::Result.error("boom"))
      expect(handler.handles?(tool_call("call-1"))).to be(true)
    end

    it "reads raw NDJSON line Strings, ignoring unparseable and non-tool_result lines" do
      lines = [
        %({"type":"tool_result","tool_use_id":"call-1","content":"hi","is_error":false}),
        %({"type":"span","message":"a rust tracing line"}),
        "not json at all"
      ]
      handler = described_class.from_journal(lines)
      expect(handler.call(tool_call("call-1"))).to eq(Lain::Tool::Result.ok("hi"))
      expect(handler.handles?(tool_call("call-1"))).to be(true)
    end
  end
end
