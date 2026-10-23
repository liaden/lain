# frozen_string_literal: true

require "tmpdir"

# A session's recorded effects belong to the past: forking at a turn or
# rewinding the live head moves a pointer over turns that already ran, and the
# bash call inside them must not run again. The counter file is the witness,
# because a re-run appends a second line.
RSpec.describe "forking and rewinding a session that already wrote", :seam do
  around do |example|
    Dir.mktmpdir("fork-no-rerun") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@dir, "state") }) }
  let(:counter) { File.join(@dir, "counter") }
  let(:journal_path) { Lain::Journal.default_path(paths:) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([Lain::Tools::Bash.new]) }
  let(:chronicle) do
    journal = Lain::Journal.new(io: File.open(journal_path, "ab"), owns_io: true, fsync: true, path: journal_path)
    Lain::CLI::Chronicle.new(journal:, journal_path:).tap { |built| built.start(context:, toolset:) }
  end
  let(:append) { { "command" => "echo written >> #{counter}" } }

  def lines = File.readlines(counter)

  def live_agent(responses)
    agent = nil
    memory = chronicle.wrap_memory(Lain::Memory::Recorder.new)
    middleware = chronicle.turn_middleware(-> { agent.timeline })
    agent = Lain::Agent.new(provider: Lain::Provider::Mock.new(responses:), context:, toolset:,
                            session: chronicle.wrap_session(Lain::Session.new(memory:)),
                            timeline: Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store),
                            instrumentation: chronicle.instrumentation.with(turn_middleware: middleware))
    agent.ask("append a line")
    agent
  end

  def scripted = [tool_response(["tu_1", "bash", append]), text_response("done"), text_response("again")]

  describe "forked at the turn after the write" do
    let(:fork_digest) do
      journal_records(journal_path, "turn").reverse.find { |record| record["role"] == "user" }.fetch("digest")
    end

    before { live_agent(scripted).tap { chronicle.close } }

    it "answers one more prompt without writing again" do
      point = Lain::CLI::ForkPoint::Point.new(path: journal_path.to_s, digest: fork_digest)
      result = Lain::CLI::Resume.new(paths:).fork_at(point)
      forked = Lain::Agent.new(provider: Lain::Provider::Mock.new(responses: [text_response("again")]), context:,
                               toolset:, session: result.session, timeline: result.timeline)

      forked.ask("anything else?")

      expect(lines).to eq(["written\n"])
    end

    it "re-renders every recorded request to its recorded digest" do
      recording = Lain::Bench::Session.load(journal_path.to_s)
      forked = recording.timeline.checkout(fork_digest)
      # The fixture holds one model call before the fork point.
      baseline = recording.baseline.take(1)
      replay = Lain::Bench::DryReplay.new(timeline: forked, baseline:, toolset:, workspace: recording.workspace)

      expect(replay.replay(recording.context).map(&:digest)).to eq(baseline.map(&:digest))
    end
  end

  it "rewinds one turn and answers the next prompt without writing again" do
    agent = live_agent(scripted)
    env = build_command_env(agent:, chronicle:)
    answered_call = agent.timeline.ancestors.to_a[1]

    Lain::CLI::Command::Rewind.new.call("1", env)
    expect(agent.timeline.head_digest).to eq(answered_call.digest)
    agent.ask("anything else?")

    expect(lines).to eq(["written\n"])
  end
end
