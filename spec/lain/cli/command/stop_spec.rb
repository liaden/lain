# frozen_string_literal: true

# `/stop` at `you>`. The prompt only ever opens between asks -- the repl
# dispatches a line and the ask it starts completes inside that dispatch -- so
# there is never a run to stop here and the command's whole job is saying so in
# words, with no model turn spent finding that out.
RSpec.describe Lain::CLI::Command::Stop do
  subject(:command) { described_class.new }

  it "registers as /stop with a usage naming where a stop does reach an ask" do
    expect(command.name).to eq("stop")
    expect(command.usage).to include("/stop").and include("s")
  end

  it "says no ask is running, whatever follows the verb" do
    ["", "  ", "now"].each do |args|
      expect(command.call(args, nil)).to eq(described_class::NOTHING_RUNNING)
    end
  end

  it "says it in words a human can act on" do
    expect(described_class::NOTHING_RUNNING).to include("no ask is running")
  end
end
