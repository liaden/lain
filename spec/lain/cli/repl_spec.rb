# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

RSpec.describe Lain::CLI::Repl do
  # The T1 AC round trip: a Provider::Mock, a Channel, and a Frontend::TTY
  # over StringIO stand in for the live edges; the Repl itself is constructed
  # through Lain::CLI::Wiring -- the exe's own assembly path, minus the exe.
  let(:offline_backend_class) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:)
        super(options)
        @mock = mock
      end

      def provider(**) = @mock
    end
  end

  let(:mock_provider) do
    Lain::Provider::Mock.new(responses: [
                               Lain::Response.new(content: [{ "type" => "text", "text" => "hello from the mock" }],
                                                  stop_reason: :end_turn)
                             ])
  end
  let(:backend) { offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: mock_provider) }

  it "settles one converse round-trip built through Wiring, and the journal records it" do
    Dir.mktmpdir do |dir|
      # Paths is injected (the chronicle_spec/journal_spec idiom), never a
      # global ENV mutation: the journal lands under this tmpdir by construction.
      paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => dir })
      chronicle = Lain::CLI::Chronicle.for(enabled: true, paths:)
      wiring = Lain::CLI::Wiring.new(options: { grace: 5 }, chronicle:)
      channel = Lain::Channel.new
      recorder, session = wiring.run_state(nil)
      agent = wiring.wire_agent(channel:, recorder:, session:, backend:)

      output = StringIO.new
      tty = Lain::Frontend::TTY.new(channel:, output:, input: StringIO.new("hello?\n"),
                                    history_path: File.join(dir, "history"))
      conductor = Lain::CLI::Conductor.open(tty:, chronicle:, grace: 5, supervisor: wiring.supervisor)
      wiring.instance_variable_set(:@conductor, conductor)
      repl = wiring.send(:build_repl, tty:, agent:)
      expect(repl).to be_a(described_class)

      repl.run(nvim: nil, store: agent.timeline.store, session:)
      conductor.close(reason: :exit)

      expect(output.string).to include("hello from the mock")

      records = Dir.glob(File.join(dir, "lain", "sessions", "**", "*.ndjson"))
                   .flat_map { |file| File.readlines(file).map { |line| JSON.parse(line) } }
      expect(records.map { |record| record.fetch("type") }).to include("session", "turn")
      expect(records.any? { |record| record["type"] == "turn" && record.to_json.include?("hello from the mock") })
        .to be(true)
    end
  end
end
