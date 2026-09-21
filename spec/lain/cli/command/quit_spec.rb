# frozen_string_literal: true

RSpec.describe Lain::CLI::Command::Quit do
  subject(:command) { described_class.new }

  it "is the /quit command and describes itself" do
    expect(command.name).to eq("quit")
    expect(command.usage).to include("/quit")
  end

  it "hands the Repl its :quit action, without printing" do
    action = nil
    expect { action = command.call("", instance_double(Lain::CLI::Command::Env)) }.not_to output.to_stdout
    expect(action).to eq(:quit)
  end
end
