# frozen_string_literal: true

require "async"
require "fileutils"
require "tmpdir"

# A human who denies a researcher's call on a path is not asked again about
# that path or anything under it, by that researcher. Everything is real
# between the model and the gate: the assembly {Lain::CLI::Wiring} builds, the
# spawn seam, the guard stack and the queue. Only the provider is scripted.
RSpec.describe "A human's deny on a gated path, remembered for its requester", :seam do
  let(:script) { [] }
  let(:provider) { Lain::Provider::Mock.new(responses: script) }
  let(:status_feed) { instance_double(Lain::StatusFeed, bind_store: nil) }
  let(:offline_backend_class) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:, root: Dir.pwd)
        super(options, root:)
        @mock = mock
      end

      def provider(**) = @mock
    end
  end
  let(:backend) { offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: provider) }

  around do |example|
    Dir.mktmpdir("lain-remembered-denial") do |dir|
      @base = File.realpath(dir)
      @home = File.join(@base, "home")
      @root = File.join(@base, "project")
      @paths = Lain::Paths.new(env: { "HOME" => @home, "XDG_STATE_HOME" => File.join(@base, "state") })
      FileUtils.mkdir_p([File.join(@home, "joel"), File.join(@home, ".ssh"), File.join(@root, "lib")])
      File.write(File.join(@root, "lib", "a.rb"), "zq_project_mark = 1\n")
      File.write(File.join(@home, ".ssh", "config"), "Host example\n")
      example.run
    end
  end

  def project = Lain::Project.new(root: @root, cwd: @root, kind: :project, detected_by: :flag)

  def wired
    wiring = Lain::CLI::Wiring.new(options: { grace: 5 }, chronicle: Lain::CLI::Chronicle::Null.new,
                                   status_feed:, project:, paths: @paths)
    recorder, session = wiring.run_state(nil)
    agent = wiring.wire_agent(channel: RecordingChannel.new, recorder:, session:, backend:, notice: ->(_line) {})
    [wiring, agent]
  end

  def calls(id, name, input) = tool_response([id, name, input])

  def blocks_sent = provider.requests.flat_map { |request| request.messages.flat_map { |m| Array(m["content"]) } }

  def result_of(id)
    block = blocks_sent.grep(Hash).find { |sent| sent["type"] == "tool_result" && sent["tool_use_id"] == id }
    raise "no tool_result answered #{id}" unless block

    Array(block["content"]).map { |part| part.is_a?(Hash) ? part["text"] : part }.join("\n")
  end

  # The human at the approval surface: denies every park, in words, and keeps
  # who asked about what.
  def asked(wiring, agent)
    seen = []
    Sync do |task|
      surface = task.async do
        loop do
          pending = wiring.approvals.dequeue
          seen << [pending.tool, pending.requester]
          pending.deny(surface: "spec", reason: "not your business")
        end
      end
      task.with_timeout(30) { agent.ask("look around") }
    ensure
      surface&.stop
    end
    seen
  end

  # The chat's own `subagent` tool spawns the researcher, which makes `child`
  # calls in turn, then the parent makes its own.
  def scripted(child:, parent: [])
    script.push(calls("tu_spawn", "subagent", { "prompt" => "look around" }),
                *child.map { |id, name, input| calls(id, name, input) }, text_response("child done"),
                *parent.map { |id, name, input| calls(id, name, input) }, text_response("parent done"))
  end

  it "asks once for the home sequence, refusing the later glob and listing in the human's words" do
    scripted(child: [["tu_1", "list_files", { "path" => @home }],
                     ["tu_2", "glob", { "path" => @home, "pattern" => "*" }],
                     ["tu_3", "list_files", { "path" => File.join(@home, "joel") }]])
    wiring, agent = wired

    expect(asked(wiring, agent)).to eq([%w[list_files researcher]])
    expect([result_of("tu_2"), result_of("tu_3")]).to all(include("not your business"))
  end

  it "still reads the project under the denied ancestor" do
    scripted(child: [["tu_1", "list_files", { "path" => @base }],
                     ["tu_2", "read_file", { "path" => File.join(@root, "lib", "a.rb") }]])
    wiring, agent = wired

    asked(wiring, agent)

    expect(result_of("tu_2")).to include("zq_project_mark")
  end

  it "asks again about a sibling name that is not under the denied path" do
    scripted(child: [["tu_1", "list_files", { "path" => File.join(@home, "jo") }],
                     ["tu_2", "list_files", { "path" => File.join(@home, "joel") }]])
    wiring, agent = wired

    expect(asked(wiring, agent)).to eq([%w[list_files researcher]] * 2)
  end

  it "asks the main agent about the path its researcher was denied" do
    ssh = File.join(@home, ".ssh", "config")
    scripted(child: [["tu_1", "read_file", { "path" => ssh }]], parent: [["tu_2", "read_file", { "path" => ssh }]])
    wiring, agent = wired

    expect(asked(wiring, agent)).to eq([%w[read_file researcher], %w[read_file agent]])
  end
end
