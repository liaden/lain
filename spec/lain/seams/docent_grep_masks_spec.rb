# frozen_string_literal: true

require "async"
require "tmpdir"

# Grep is a second road to bytes a denied release left masked; only the provider is scripted.
RSpec.describe "A diff docent's grep after a release was answered", :seam do
  let(:token) { "ghp_#{"a1B2c3D4e5" * 3}abcdef" }
  let(:script) { [] }
  let(:provider) { Lain::Provider::Mock.new(responses: script) }
  let(:status_feed) { instance_double(Lain::StatusFeed, bind_store: nil) }
  let(:journal_path) { File.join(@root, "session.ndjson") }
  let(:journal) { Lain::Journal.open(journal_path) }
  let(:backend) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:, root: Dir.pwd)
        super(options, root:)
        @mock = mock
      end

      def provider(**) = @mock
    end.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: provider)
  end

  around do |example|
    Dir.mktmpdir("lain-docent-grep") do |dir|
      @root = File.realpath(dir)
      FileUtils.mkdir_p(File.join(@root, "config"))
      File.write(File.join(@root, "config", "gh.yml"), "name: ci\ntoken: #{token}\n")
      Dir.chdir(@root) { example.run }
    end
  end

  def project = Lain::Project.new(root: @root, cwd: @root, kind: :project, detected_by: :flag)

  def wiring
    chronicle = Lain::CLI::Chronicle.new(journal:, journal_path:)
    @wiring ||= Lain::CLI::Wiring.new(options: { grace: 5 }, chronicle:, status_feed:, project:)
  end

  def result_of(id)
    block = provider.requests.flat_map { |r| r.messages.flat_map { |m| Array(m["content"]) } }.grep(Hash)
                    .find { |sent| sent["type"] == "tool_result" && sent["tool_use_id"] == id }
    raise "no tool_result answered #{id}" unless block

    Array(block["content"]).map { |part| part.is_a?(Hash) ? part["text"] : part }.join("\n")
  end

  def script_read_then_grep
    script.push(tool_response(["tu_read", "read_file", { "path" => "config/gh.yml" }]), text_response("parent done"),
                tool_response(["tu_grep", "grep", { "pattern" => "ghp_", "path" => "config" }]),
                text_response("docent done"))
  end

  def read_then_docent_grep(approve:)
    script_read_then_grep
    agent = wired_agent
    Sync do |task|
      human = task.async { loop { answer(wiring.approvals.dequeue, approve:) } }
      task.with_timeout(30) do
        agent.ask("read it")
        wiring.role_spawn.call(:diff_docent, :fresh, "what is in config?")
      end
    ensure
      human.stop
    end
    journal.close
  end

  def wired_agent
    recorder, session = wiring.run_state(nil)
    wiring.wire_agent(channel: RecordingChannel.new, recorder:, session:, backend:, notice: ->(_line) {})
  end

  def answer(pending, approve:)
    approve ? pending.approve(surface: "spec") : pending.deny(surface: "spec")
  end

  it "keeps the denied region masked in the child's row and out of the journal file" do
    read_then_docent_grep(approve: false)

    expect(result_of("tu_read")).to include("<redacted:1>").and(satisfy { |text| !text.include?(token) })
    expect(result_of("tu_grep")).to include("gh.yml:2:token: <redacted:1>")
    expect(result_of("tu_grep")).not_to include(token)
    expect(File.read(journal_path)).not_to include(token)
  end

  it "leaves the row unmasked when the release was approved" do
    read_then_docent_grep(approve: true)

    expect(result_of("tu_read")).to include(token)
    expect(result_of("tu_grep")).to include("gh.yml:2:token: #{token}")
  end
end
