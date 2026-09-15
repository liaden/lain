# frozen_string_literal: true

# The shared predicate `/rewind`, `/undo`, `/fork` and `/btw` all ask before
# they move or open anything, off one agent's dispatch lock -- see
# `lib/lain/cli/command/in_flight.rb` for the wider design note.
RSpec.describe Lain::CLI::Command::InFlight do
  let(:pending_turn) do
    instance_double(Lain::Event, role: "assistant",
                                 content: [{ "type" => "tool_use", "id" => "toolu_01", "name" => "echo",
                                             "input" => { "text" => "hi" } }])
  end
  let(:settled_turn) { instance_double(Lain::Event, role: "user", content: [{ "type" => "text", "text" => "hi" }]) }

  def env_for(dispatching:, head:)
    timeline = instance_double(Lain::Timeline, head:)
    agent = instance_double(Lain::Agent, timeline:, dispatching?: dispatching)
    build_command_env(agent:)
  end

  describe ".dispatching?" do
    it "reads straight off the agent's dispatch lock, whatever the head holds" do
      expect(described_class.dispatching?(env_for(dispatching: true, head: settled_turn))).to be(true)
      expect(described_class.dispatching?(env_for(dispatching: false, head: pending_turn))).to be(false)
    end
  end

  describe ".mid_tool?" do
    it "is true only while the live head IS the parked call: dispatching, with a pending tool_use" do
      expect(described_class.mid_tool?(env_for(dispatching: true, head: pending_turn))).to be(true)
    end

    it "is false at rest, even over a stranded tool_use head" do
      expect(described_class.mid_tool?(env_for(dispatching: false, head: pending_turn))).to be(false)
    end

    it "is false while dispatching a plain reply with no tool_use pending yet" do
      expect(described_class.mid_tool?(env_for(dispatching: true, head: settled_turn))).to be(false)
    end
  end
end
