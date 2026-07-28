# frozen_string_literal: true

require "json"
require "pastel"
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
    # `**` swallows T13's `prompt_renderer:` -- this spec is about the chat
    # round trip, and its StringIO input never reaches the composing path.
    tty_factory = lambda do |channel:, **|
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

  # T9: what a command may hand the Repl back. A String stays a first-class
  # return forever; a {Lain::Renderable} is the second, structured one. Driven
  # through the PUBLIC #converse (a conductor whose next read is nil ends the
  # loop), never a send(:settle_command) -- the same no-ivar-pokes discipline
  # the round trip above keeps.
  describe "what a command returns (T9)" do
    let(:colored) { Pastel.new(enabled: true) }
    let(:conductor) { instance_double(Lain::CLI::Conductor, read_prompt: nil, closed?: false) }

    def tty_over(output, enabled:, dir:)
      pastel = Pastel.new(enabled:)
      Lain::Frontend::TTY.new(channel: Lain::Channel.new, output:, input: StringIO.new, pastel:,
                              theme: Lain::Frontend::Theme.new(pastel:, detect: -> { 256 }),
                              history_path: File.join(dir, "history"))
    end

    def settle(outcome, tty:)
      commands = Struct.new(:outcome) do
        def dispatch(_text) = outcome
      end.new(outcome)
      Lain::CLI::Repl.new(agent: instance_double(Lain::Agent, timeline: nil), tty:,
                          replies: instance_double(Lain::CLI::HumanReplies), commands:,
                          chronicle: Lain::CLI::Chronicle::Null.new, conductor:)
                     .converse(first_prompt: "/anything")
    end

    def settled_output(outcome, enabled: true)
      Dir.mktmpdir do |dir|
        output = StringIO.new
        settle(outcome, tty: tty_over(output, enabled:, dir:))
        output.string
      end
    end

    it "renders a renderable's named segment in the theme's own style for that token" do
      warm = Lain::Renderable.new.plain("cache ").with(:warm, "warm")

      expect(settled_output(warm)).to include(colored.green("warm"))
    end

    it "leaves the surrounding text out of that segment's colour" do
      warm = Lain::Renderable.new.plain("cache ").with(:warm, "warm")

      expect(settled_output(warm)).to include("cache #{colored.green("warm")}")
    end

    it "still delivers a plain String exactly as it does today" do
      expect(settled_output("just words")).to include(colored.cyan("just words"))
    end

    it "ends the conversation on :quit -- the next prompt is never read" do
      Dir.mktmpdir do |dir|
        settle(:quit, tty: tty_over(StringIO.new, enabled: false, dir:))

        expect(conductor).not_to have_received(:read_prompt)
      end
    end

    it "names an unrecognised return loudly, and recoverably" do
      expect(settled_output(42, enabled: false)).to include("error:", "42")
    end

    it "names the COMMAND in that breach, not only what it returned" do
      expect(settled_output(42, enabled: false)).to include("command /anything returned")
    end

    it "carries no ANSI escapes when the stream is not a terminal" do
      warm = Lain::Renderable.new.plain("cache ").with(:warm, "warm")

      expect(settled_output(warm, enabled: false)).not_to include("\e[")
    end
  end
end
