# frozen_string_literal: true

# `/park text` leaves a re-entry note in the session record. Zero model turns.
RSpec.describe Lain::CLI::Command::Park do
  subject(:command) { described_class.new }

  let(:journal) { [] }
  let(:session) { Lain::Session.new(journal:) }
  let(:agent) do
    Lain::Agent.new(provider: Lain::Provider::Mock.new(responses: []), toolset: Lain::Toolset.new([EchoTool.new]),
                    context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse"),
                    session:)
  end
  let(:env) { build_command_env(agent:) }

  it "is the /park command and describes itself" do
    expect(command.name).to eq("park")
    expect(command.usage).to include("/park")
  end

  it "journals the note and says it is noted" do
    reply = command.call("waiting on review from X; next: address comments", env)

    expect(journal.select { _1.journal_type == "reentry_note" }.map(&:note))
      .to eq(["waiting on review from X; next: address comments"])
    expect(reply).to include("noted").and include("waiting on review from X")
  end

  it "keeps the latest note and clears it on an empty park" do
    command.call("first", env)
    command.call("second", env)
    expect(session.reentry_note).to eq("second")

    reply = command.call("", env)

    expect(session.reentry_note).to eq("")
    expect(reply).to include("cleared")
  end
end
