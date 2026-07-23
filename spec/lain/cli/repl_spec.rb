# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

RSpec.describe Lain::CLI::Repl do
  # The T1 AC round trip: a Provider::Mock, a Channel, and a Frontend::TTY over
  # StringIO stand in for the live edges; the Repl is constructed AND run
  # through Lain::CLI::Wiring#run -- the exe's own assembly path, minus the exe
  # -- via the injected tty seam (T9: no send(:build_repl), no ivar pokes).
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

  def run_chat(input, dir:, chronicle: Lain::CLI::Chronicle::Null.new, options: { grace: 5 })
    output = StringIO.new
    tty_factory = lambda do |channel:|
      Lain::Frontend::TTY.new(channel:, output:, input: StringIO.new(input),
                              history_path: File.join(dir, "history"))
    end
    wiring = Lain::CLI::Wiring.new(options:, chronicle:, tty_factory:,
                                   status_feed: instance_double(Lain::StatusFeed))
    wiring.run(backend:, resumed: nil, nvim: nil)
    wiring.conductor.close(reason: :exit)
    output.string
  end

  it "settles one converse round-trip built through Wiring, and the journal records it" do
    Dir.mktmpdir do |dir|
      # Paths is injected (the chronicle_spec/journal_spec idiom), never a
      # global ENV mutation: the journal lands under this tmpdir by construction.
      paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => dir })
      chronicle = Lain::CLI::Chronicle.for(enabled: true, paths:)

      output = run_chat("hello?\n", dir:, chronicle:)

      expect(output).to include("hello from the mock")

      records = Dir.glob(File.join(dir, "lain", "sessions", "**", "*.ndjson"))
                   .flat_map { |file| File.readlines(file).map { |line| JSON.parse(line) } }
      expect(records.map { |record| record.fetch("type") }).to include("session", "turn")
      expect(records.any? { |record| record["type"] == "turn" && record.to_json.include?("hello from the mock") })
        .to be(true)
    end
  end

  describe "command dispatch (T9)" do
    it "consults the registry before the skill middleware: /help runs lib-side, zero model turns" do
      Dir.mktmpdir do |dir|
        output = run_chat("/help\n", dir:)

        expect(output).to include("/help", "/quit")
        expect(output).to include("skills:")
        expect(mock_provider.call_count).to eq(0)
      end
    end

    it "an unregistered /word still reaches SkillDispatch unchanged" do
      Dir.mktmpdir do |dir|
        output = run_chat("/nope\n", dir:)

        expect(output).to include("unknown skill \"nope\"")
        expect(mock_provider.call_count).to eq(0)
      end
    end

    it "/quit winds down through the same path as bare quit -- the next line is never read" do
      Dir.mktmpdir do |dir|
        output = run_chat("/quit\nnever dispatched\n", dir:)

        expect(mock_provider.call_count).to eq(0)
        expect(output).not_to include("hello from the mock")
      end
    end
  end
end
