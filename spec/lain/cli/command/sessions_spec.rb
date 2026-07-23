# frozen_string_literal: true

# T13: /sessions renders Command::Env's `sessions` reader ({Lain::CLI::Sessions}'s
# own #listing) verbatim -- no re-derivation here, matching /status's "one
# definition, read twice" shape.
RSpec.describe Lain::CLI::Command::Sessions do
  def env_with(sessions:)
    Lain::CLI::Command::Env.new(
      status: Lain::CLI::Command::Env::NullStatus, sessions:,
      approvals: Lain::CLI::Command::Env::NullApprovals, supervisor: Lain::Supervisor::Null,
      replies: double("replies"), fork_point: Lain::CLI::Command::Env::NullForkPoint,
      tmux_surface: instance_double(Lain::CLI::TmuxSurface), agent: double("agent"),
      policy_switch: Lain::CLI::Command::Env::NullPolicySwitch,
      model_switch: Lain::CLI::Command::Env::NullModelSwitch, chronicle: Lain::CLI::Chronicle::Null.new
    )
  end

  let(:command) { described_class.new }
  let(:sessions) { instance_double(Lain::CLI::Sessions) }

  it "renders CLI::Sessions#listing with the default (durable-only) view" do
    allow(sessions).to receive(:listing).with(all: false).and_return("a.ndjson  ...\nb.ndjson  ...")

    expect(command.call("", env_with(sessions:))).to eq("a.ndjson  ...\nb.ndjson  ...")
  end

  it "passes all: true for --all, including ephemeral .btw sessions" do
    allow(sessions).to receive(:listing).with(all: true).and_return("a.btw.ndjson  ...")

    expect(command.call("--all", env_with(sessions:))).to eq("a.btw.ndjson  ...")
  end

  it "treats a bare 'all' argument the same as --all" do
    allow(sessions).to receive(:listing).with(all: true).and_return("a.btw.ndjson  ...")

    expect(command.call("all", env_with(sessions:))).to eq("a.btw.ndjson  ...")
  end

  it "answers a one-line usage and returns rendered text without printing" do
    allow(sessions).to receive(:listing).with(all: false).and_return("no sessions recorded under here")

    text = nil
    expect { text = command.call("", env_with(sessions:)) }.not_to output.to_stdout
    expect(text).to be_a(String)
    expect(command.usage).to start_with("/sessions")
  end
end
