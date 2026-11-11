# frozen_string_literal: true

RSpec.describe Lain::CLI::Command::Clear do
  let(:env) { instance_double(Lain::CLI::Command::Env) }

  it "is the /clear command and describes itself" do
    command = described_class.new(pane: nil)

    expect(command.name).to eq("clear")
    expect(command.usage).to include("/clear")
  end

  it "hands the Repl its :restart action once the cockpit has the respawn scheduled" do
    asked = nil
    restart = lambda { |**kwargs|
      asked = kwargs
      true
    }

    expect(described_class.new(pane: "%3", restart:).call("", env)).to eq(:restart)
    expect(asked).to eq(pane: "%3")
  end

  it "refuses outside a cockpit, naming /rewind 0 as the in-place way to empty the context" do
    command = described_class.new(pane: "%3", restart: ->(**) { false })

    expect { command.call("", env) }
      .to raise_error(Lain::Error, %r{plain chat has no cockpit pane to restart.*/rewind 0}m)
  end

  it "stays in the chat and says the restart could not be set up when tmux refuses" do
    restart = ->(**) { raise Lain::CLI::Up::TmuxUnavailable, "tmux run-shell failed: boom" }

    expect { described_class.new(pane: "%3", restart:).call("", env) }
      .to raise_error(Lain::Error, /restart could not be set up.*boom/m)
  end
end
