# frozen_string_literal: true

# A driver that ran, as the command sees one.
class ImplementEpicSpecDriver
  def initialize(reply) = @reply = reply
  attr_reader :width, :budget

  def run(width: nil, budget: nil)
    @width = width
    @budget = budget
    @reply
  end
end

# `/implement-epic` at `you>`: work the mounted epic's approved issues to its
# working branch, reporting each as it lands. The driving lives in
# {CLI::EpicDriver::Run}; this command is only the door onto it, so what these
# examples pin is the door -- what it is called, what it hands back, and how it
# refuses a chat that is in no epic.
RSpec.describe Lain::CLI::Command::ImplementEpic do
  let(:command) { described_class.new }

  it "is named for the verb a human types, and says what it does" do
    expect(command.name).to eq("implement-epic")
    expect(command.usage).to include("/implement-epic")
  end

  it "runs the mounted epic's driver and hands back what it reported" do
    driver = ImplementEpicSpecDriver.new("landed a at sha-a")

    expect(command.call("", build_command_env(epic_driver: driver))).to include("landed a at sha-a")
  end

  # The refusal is the Null's, raised rather than returned: a chat in no epic
  # must not read a line of success, and the Repl renders a Lain::Error loudly.
  it "refuses by name when no epic is mounted, naming --epic" do
    env = build_command_env(epic_driver: Lain::CLI::EpicDriver::Factory::Unmounted)

    expect { command.call("", env) }.to raise_error(Lain::CLI::EpicDriver::NoEpicMounted, /--epic/)
  end

  # The width is a knob, so a human who wants the issues taken one at a time can
  # say so without editing a config file.
  it "passes a width the human typed through to the run" do
    driver = ImplementEpicSpecDriver.new("done")

    command.call("--width 3", build_command_env(epic_driver: driver))

    expect(driver.width).to eq(3)
  end

  it "refuses a width that is not a positive number, rather than driving with a default" do
    env = build_command_env(epic_driver: ImplementEpicSpecDriver.new("done"))

    expect { command.call("--width nope", env) }.to raise_error(Lain::Error, /width/)
  end
end
