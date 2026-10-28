# frozen_string_literal: true

# `/label [digest] text` names a committed turn in the session record. Zero
# model turns; the digest resolution is /pin's, so an ambiguous prefix refuses
# the way /pin refuses it.
RSpec.describe Lain::CLI::Command::Label do
  subject(:command) { described_class.new }

  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:provider) { Lain::Provider::Mock.new(responses: [text_response("one"), text_response("two")]) }
  let(:journal) { [] }
  let(:session) { Lain::Session.new(journal:) }
  let(:agent) do
    Lain::Agent.new(provider:, toolset:, context:, session:).tap do |built|
      built.ask("first")
      built.ask("second")
    end
  end
  let(:env) { build_command_env(agent:) }
  let(:digests) { agent.timeline.ancestor_digests.to_a }

  def hex(digest) = digest.delete_prefix("blake3:")

  it "is the /label command and describes itself" do
    expect(command.name).to eq("label")
    expect(command.usage).to include("/label")
  end

  # Scenario: a label is journaled and restored
  it "labels the head with text that is not a digest, and journals it" do
    text = command.call("tried the cache idea", env)

    expect(session.labels).to eq(agent.timeline.head_digest => "tried the cache idea")
    expect(journal.map(&:journal_type)).to include("turn_labeled")
    expect(text).to include("labeled").and include("tried the cache idea")
  end

  # Scenario: a label on a digest prefix
  it "labels the turn a leading digest prefix names, with the rest as the text" do
    target = digests.last

    command.call("#{hex(target)[0, 8]} before refactor", env)

    expect(session.labels).to eq(target => "before refactor")
  end

  it "keeps a leading hex-looking word that names no turn as part of the text" do
    command.call("deadbeef is the bug", env)

    expect(session.labels).to eq(agent.timeline.head_digest => "deadbeef is the bug")
  end

  it "refuses a prefix more than one turn matches, and labels nothing" do
    expect { command.call("blake3: before refactor", env) }.to raise_error(Lain::Error, /ambiguous/)
    expect(session.labels).to eq({})
  end

  # Scenario: an empty label clears
  it "journals an empty label when a digest is named with no text, and clears the label" do
    target = digests.last
    session.record_label(target, "old")

    text = command.call(hex(target)[0, 8], env)

    expect(session.labels).to eq({})
    expect(journal.select { |record| record.journal_type == "turn_labeled" }.map(&:label)).to eq(["old", ""])
    expect(text).to include("cleared")
  end

  it "refuses on a session with no committed turns" do
    empty = Lain::Agent.new(provider:, toolset:, context:, session:)

    expect { command.call("x", build_command_env(agent: empty)) }.to raise_error(Lain::Error, /no committed turns/)
  end
end
