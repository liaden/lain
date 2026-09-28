# frozen_string_literal: true

require "json"
require "tmpdir"

# A driver that ran, as the command sees one.
class ImplementEpicSpecDriver
  def initialize(reply) = @reply = reply
  attr_reader :width, :budget, :resumed

  def run(width: nil, budget: nil, resumed: nil)
    @width = width
    @budget = budget
    @resumed = resumed
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

    expect { command.call("", env) }.to raise_error(Lain::Error, /this chat is in no epic/)
  end

  # The width is a knob, so a human who wants the issues taken one at a time can
  # say so without editing a config file.
  it "passes a width the human typed through to the run" do
    driver = ImplementEpicSpecDriver.new("done")

    command.call("--width 3", build_command_env(epic_driver: driver))

    expect(driver.width).to eq(3)
  end

  # Untyped, the width is left UNSAID rather than defaulted here: what a run
  # carries when nobody typed one is the driver's to resolve, from the project's
  # `[epics] width` and from where its models run. A default spelled here would
  # be a second answer to that, and the one a human never sees.
  it "leaves the width unsaid when the human typed none" do
    driver = ImplementEpicSpecDriver.new("done")

    command.call("", build_command_env(epic_driver: driver))

    expect(driver.width).to be_nil
  end

  it "refuses a width that is not a positive number, rather than driving with a default" do
    env = build_command_env(epic_driver: ImplementEpicSpecDriver.new("done"))

    expect { command.call("--width nope", env) }.to raise_error(Lain::Error, /width/)
  end

  # This command used to read only `--width N` through a whole-string regex,
  # so a mistyped flag beside a stray word answered a generic "takes only
  # --width N" that never named which word was wrong.
  it "refuses a mistyped flag, naming it, ahead of the word beside it" do
    env = build_command_env(epic_driver: ImplementEpicSpecDriver.new("done"))

    expect { command.call("plans --wdith 1", env) }.to raise_error(Lain::Error, /--wdith/)
  end

  it "refuses a bare word, this command reading no positional at all" do
    env = build_command_env(epic_driver: ImplementEpicSpecDriver.new("done"))

    expect { command.call("plans", env) }.to raise_error(Lain::Error, /plans/)
  end

  # A chat resumed mid-epic, after a crash most often, is carrying on the run
  # its branches belong to: the driver keeps them rather than asking.
  context "when deciding whether the chat carrying the run was resumed" do
    def over_session(header)
      driver = ImplementEpicSpecDriver.new("done")
      Dir.mktmpdir("lain-implement-epic") do |dir|
        path = File.join(dir, "session.ndjson")
        File.write(path, "#{JSON.generate(header)}\n")
        chronicle = instance_double(Lain::CLI::Chronicle, journal_path: path)
        command.call("", build_command_env(epic_driver: driver, chronicle:))
      end
      driver.resumed
    end

    it "tells the driver so when the session's header chains from an earlier one" do
      resumed_from = { "file" => "earlier.ndjson", "head" => "blake3:ab" }

      expect(over_session({ "type" => "session", "resumed_from" => resumed_from })).to be(true)
    end

    it "tells the driver it was not for a fresh session" do
      expect(over_session({ "type" => "session" })).to be(false)
    end

    it "tells the driver it was not for a chat that keeps no session file" do
      driver = ImplementEpicSpecDriver.new("done")

      command.call("", build_command_env(epic_driver: driver))

      expect(driver.resumed).to be(false)
    end
  end
end
