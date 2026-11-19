# frozen_string_literal: true

require "tmpdir"

# `/park text` leaves a re-entry note in the session record. Zero model turns.
RSpec.describe Lain::CLI::Command::Park do
  subject(:command) { described_class.new(root: "/work/proj", notes: Lain::Sink::Null.new, feed:) }

  let(:feed) { ->(*note) { fed << note } }
  let(:fed) { [] }
  let(:tokens) { [] }
  let(:reporter) do
    sent = tokens
    Object.new.tap do |own|
      own.define_singleton_method(:metadata) { |*args| sent << args }
      own.define_singleton_method(:mask) { Lain::Herdr::Reporter::MASK }
    end
  end

  let(:journal) { [] }
  let(:session) { Lain::Session.new(journal:) }
  let(:agent) do
    Lain::Agent.new(provider: Lain::Provider::Mock.new(responses: []), toolset: Lain::Toolset.new([EchoTool.new]),
                    context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse"),
                    session:)
  end
  let(:env) { build_command_env(agent:, reporter:) }

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

  it "writes the feed at once with the project as its title" do
    command.call("waiting on CI", env)

    expect(fed).to eq([["lain", "proj", "parked: waiting on CI"]])
  end

  it "masks a secret-named environment value in the feed body" do
    value = "opensesame-plain-words-42"
    with_env("LAIN_SPEC_PARK_TOKEN" => value) { command.call("echo #{value}", env) }

    expect(fed.sole.last).to start_with("parked: echo").and(satisfy { !_1.include?(value) })
  end

  it "masks a secret-named environment value in the journaled note, the pane token and the reply" do
    value = "opensesame-plain-words-42"
    reply = with_env("LAIN_SPEC_PARK_TOKEN" => value) { command.call("echo #{value}", env) }

    expect([session.reentry_note, tokens.sole.last, reply]).to all(include("echo"))
    expect([session.reentry_note, tokens.sole.last, reply].join).not_to include(value)
  end

  it "sets lain's own pane token, never one named parked" do
    command.call("waiting on CI", env)

    expect(tokens).to eq([["lain_parked", "waiting on CI"]])
  end

  it "clears the token and writes nothing to the feed on an empty park" do
    command.call("  ", env)

    expect([tokens, fed]).to eq([[["lain_parked", nil]], []])
  end

  it "names a failing notify-feed on the notes it is given" do
    Dir.mktmpdir("park-feed") do |dir|
      File.write(File.join(dir, "notify-feed"), "#!/bin/sh\nexit 1\n", perm: 0o755)
      notes = StringIO.new

      described_class.new(root: "/work/proj", env: { "PATH" => dir }, notes:).call("waiting on CI", env)

      expect(notes.string).to eq("#{File.join(dir, "notify-feed")} exited 1\n")
    end
  end

  it "runs the machine's notify-feed when no feed is handed in" do
    Dir.mktmpdir("park-feed") do |dir|
      out = File.join(dir, "out")
      File.write(File.join(dir, "notify-feed"), "#!/bin/sh\n{ printf '%s|' \"$@\"; cat; } > #{out}\n", perm: 0o755)

      described_class.new(root: "/work/proj", env: { "PATH" => dir }, notes: StringIO.new).call("waiting on CI", env)

      expect(File.read(out)).to eq("lain|proj|parked: waiting on CI")
    end
  end
end
