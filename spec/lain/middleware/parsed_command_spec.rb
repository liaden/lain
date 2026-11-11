# frozen_string_literal: true

require "async"
require "stringio"
require "tmpdir"

RSpec.describe Lain::Middleware::ParsedCommand do
  subject(:middleware) { described_class.new(home: "/home/u") }

  let(:context) { Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: "/p", env: {})) }

  def bash(input) = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input:)

  def run(effect)
    seen = nil
    middleware.call(Lain::Middleware::Env.wrap({ effect:, context: })) { |env| (seen = env).merge(result: :done) }
    seen
  end

  it "hands the next member the parse of a bash call's command" do
    named = run(bash({ "command" => "cat a", "cwd" => "sub" })).fetch(:named)

    expect(named.paths.map(&:resolved)).to eq(%w[/p/sub/a])
  end

  it "gives the context the command's parse, for each reader to take its own view of" do
    parsed = run(bash({ "command" => "cat a" }))[:context].parsed_command

    expect(parsed).to be_a(Lain::Shell::Parse::Result).and(have_attributes(source: "cat a"))
  end

  it "carries an unreadable parse when a bash call names no command" do
    expect(run(bash({})).fetch(:named)).to equal(Lain::Shell::Named::UNREADABLE)
  end

  it "leaves a call to another tool as it came" do
    read = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file", input: { "path" => "a" })

    expect(run(read)[:named]).to be_nil
  end

  it "reads an approval around a bash call as the call" do
    wrapped = Lain::Effect::Approval.new(effect: bash({ "command" => "cat a" }))

    expect(run(wrapped).fetch(:named).paths.map(&:resolved)).to eq(%w[/p/a])
  end

  describe ".carried" do
    it "answers the context's parse of that command" do
      env = run(bash({ "command" => "cat a" }))

      expect(described_class.carried("cat a", env[:context])).to equal(env[:context].parsed_command)
    end

    it "answers nil for a command the context's parse is not of" do
      expect(described_class.carried("cat b", run(bash({ "command" => "cat a" }))[:context])).to be_nil
    end

    it "answers nil for a context that carries no parse" do
      expect(described_class.carried("cat a", context)).to be_nil
    end
  end

  # One parse serves the gate, triage, the rules, the judge, the write journal and the stages the tool reads.
  describe "a bash call through a chat's production stack", :seam do
    let(:journal_io) { StringIO.new }
    let(:chronicle) do
      Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io), journal_path: "parsed.ndjson")
    end
    let(:backend_class) do
      Class.new(Lain::CLI::Backend) do
        def initialize(options, mock:, root: Dir.pwd, **)
          super(options, root:, **)
          @mock = mock
        end

        def provider(**) = @mock
      end
    end
    let(:judge) { Lain::Provider::Mock.new(responses: []) }

    around do |example|
      Dir.mktmpdir("lain-parsed-command") do |dir|
        @base = File.realpath(dir)
        @root = File.join(@base, "repo")
        FileUtils.mkdir_p([File.join(@root, "lib"), File.join(@base, "home"), File.join(@base, "state")])
        File.write(File.join(@root, "lib", "a.rb"), "foo = 1\n")
        example.run
      end
    end

    around do |example|
      was = ENV.fetch("PATH")
      ENV["PATH"] = "/usr/bin:/bin"
      example.run
    ensure
      ENV["PATH"] = was
    end

    def board(**options)
      wiring = Lain::CLI::Wiring.new(
        options: { grace: 5, approval: "auto", confine: "classes", **options }, chronicle:,
        status_feed: instance_double(Lain::StatusFeed, bind_store: nil), project: throwaway_project(@root),
        paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@base, "state"),
                                      "HOME" => File.join(@base, "home") })
      )
      recorder, session = wiring.run_state(nil)
      backend = backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: judge, root: @root)
      wiring.wire_agent(channel: Lain::Channel.new, recorder:, session:, backend:)
      [wiring.instance_variable_get(:@switchboard), session]
    end

    # @return [Array(Lain::Tool::Result, Integer)] the call's result, and how many times its command was parsed
    def dispatched(command, **options)
      switchboard, session = board(**options)
      layers = Lain::CLI::ToolGuard.stack(chronicle, switchboard).to_a
      count = 0
      allow(Lain::Ext::TreeSitter).to receive(:query).and_wrap_original do |original, source, language, *rest|
        count += 1 if language == Lain::Shell::Parse::LANGUAGE && source == command
        original.call(source, language, *rest)
      end
      result = Sync do |task|
        task.with_timeout(20) do
          dispatch_call("bash", { "command" => command }, toolset: switchboard.toolset, layers:, context: session)
        end
      end
      [result, count]
    end

    def settled_by = journal_records(journal_io, "escalation").last

    it "parses the command exactly once, and runs it on a rule's approval" do
      result, parses = dispatched("cd lib && grep -n foo a.rb | head")

      expect(result).to have_attributes(is_error: false, content: include("1:foo = 1"))
      expect(settled_by).to include("rung" => "rules", "verdict" => "allow")
      expect(parses).to eq(1)
    end

    context "with a judge that approves a call no rule settles" do
      let(:judge) do
        Lain::Provider::Mock.new(responses: [Lain::Response.new(content: [{ "type" => "text", "text" => "approve" }],
                                                                stop_reason: :end_turn)])
      end

      def judged_prompt = judge.last_request.messages.sole.fetch("content")

      it "parses a command no rule settles exactly once on the judge's approval" do
        result, parses = dispatched("cd lib && grep -rn foo . | head")

        expect(result).to have_attributes(is_error: false, content: include("./a.rb:1:foo = 1"))
        expect(settled_by).to include("rung" => "auto", "verdict" => "allow")
        expect(parses).to eq(1)
      end

      # Facts resolve only what the verdict allows; the `cd` above leaves them unresolved, which bars the judge.
      it "builds the judge's facts from the carried parse, parsing the command exactly once" do
        result, parses = dispatched("grep -rn foo lib | head", judge_facts: "facts")

        expect(result).to have_attributes(is_error: false, content: include("lib/a.rb:1:foo = 1"))
        expect(settled_by).to include("rung" => "auto", "verdict" => "allow")
        expect(judged_prompt).to include("facts (computed by lain", "grep -> /usr/bin/grep [system]")
        expect(parses).to eq(1)
      end
    end
  end
end
