# frozen_string_literal: true

require "async"
require "base64"
require "fileutils"
require "tmpdir"

# A secret the run was lent, or that history holds, must not sit in the session
# file in a spelling the masks know. The agent is assembled by the production
# wiring over a real Journal; only the model's provider is a stand-in.
RSpec.describe "a lent secret in the session file", :seam do
  let(:offline_backend_class) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:, root:)
        super(options, root:)
        @mock = mock
      end

      def provider(**) = @mock
    end
  end
  let(:lent) { canary }
  let(:canary) { "notreal-quiet-harbour-lantern-moss" }
  let(:decoy_fixture) { File.expand_path("../../fixtures/secrets/decoy.env", __dir__) }

  around do |example|
    Dir.mktmpdir("lain-secrets-at-rest") do |dir|
      base = File.realpath(dir)
      @root = File.join(base, "repo")
      @state = File.join(base, "s")
      homes = { "XDG_STATE_HOME" => @state, "HOME" => File.join(base, "h") }
      @paths = Lain::Paths.new(env: homes)
      tmp = File.join(base, "t")
      FileUtils.mkdir_p([@root, tmp, *homes.values])
      # The TMPDIR sits beside home because the workspace profile a bypassed call runs in refuses one holding it.
      with_env(homes.merge("TMPDIR" => tmp)) { example.run }
    end
  end

  def bash_call(id, command)
    { "type" => "tool_use", "id" => id, "name" => "bash", "input" => { "command" => command } }
  end

  def mock_for(commands)
    calls = commands.each_with_index.map do |command, i|
      Lain::Response.new(content: [bash_call("tu_#{i}", command)], stop_reason: :tool_use)
    end
    Lain::Provider::Mock.new(responses: [*calls, Lain::Response.new(content: [{ "type" => "text", "text" => "done" }],
                                                                    stop_reason: :end_turn)])
  end

  # @return [Array(String, Array<Hash>)] the session file's raw bytes, and its tool results
  def session_after(commands)
    chronicle = Lain::CLI::Chronicle.for(enabled: true, paths: @paths, root: @root)
    path = chronicle.journal_path
    begin
      drive(chronicle, mock_for(commands))
    ensure
      chronicle.close(reason: :exit)
    end
    [File.binread(path), journal_records(path)]
  end

  def drive(chronicle, mock)
    project = Lain::Project.new(root: @root, cwd: @root, kind: :project, detected_by: :flag)
    wiring = Lain::CLI::Wiring.new(human: Lain::CLI::Human.new(kind: :terminal),
                                   options: { grace: 5, approval: "bypass" }, chronicle:,
                                   status_feed: Lain::StatusFeed.new(path: File.join(@state, "state.json")),
                                   project:, paths: @paths)
    lend_canary(wiring, project)
    backend = offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock:, root: @root)
    recorder, session = wiring.run_state(nil)
    agent = wiring.wire_agent(channel: Lain::Channel.new, recorder:, session:, backend:)
    Sync { |task| task.with_timeout(60) { agent.ask("go") } }
  end

  def lend_canary(wiring, project)
    chat_env = Lain::WorkerEnv.default.with(cwd: project.cwd, env: { "CANARY_API_TOKEN" => lent })
    wiring.define_singleton_method(:chat_env) { chat_env }
  end

  def spellings(secret)
    { plain: secret, assignment: "KEY=#{secret}", base64: Base64.strict_encode64(secret), hex: secret.unpack1("H*") }
  end

  def reshaped(secret)
    { reversed: secret.reverse, rot13: secret.tr("A-Za-z", "N-ZA-Mn-za-m") }
  end

  def state_bytes = Dir.glob(File.join(@state, "**", "*.{ndjson,wal}")).map { File.binread(_1) }.join

  def result_contents(records) = tool_results(records).map { _1["content"] }.tap { expect(_1.size).to eq(1) }

  def tool_results(records)
    records.flat_map { |record| Array(record["content"]) }.grep(Hash).select { _1["type"] == "tool_result" }
  end

  {
    plain: "printenv CANARY_API_TOKEN",
    assignment: 'echo "KEY=$CANARY_API_TOKEN"'
  }.each do |name, command|
    it "masks the #{name} spelling with a placeholder" do
      bytes, records = session_after([command])

      expect(result_contents(records)).to all(include("<redacted:1>"))
      expect(bytes).not_to include(spellings(canary).fetch(name))
      expect(state_bytes).not_to include(canary)
    end
  end

  {
    base64: ["printenv CANARY_API_TOKEN | base64 -w0", Base64.strict_encode64("notreal-quiet-harbour-lantern-moss")],
    hex: ["printenv CANARY_API_TOKEN | tr -d '\n' | xxd -p -c 256", "notreal-quiet-harbour-lantern-moss".unpack1("H*")]
  }.each do |name, (command, spelled)|
    it "withholds the output holding the #{name} spelling" do
      bytes, records = session_after([command])

      expect(result_contents(records)).to all(include("output withheld"))
      expect(bytes).not_to include(spelled)
      expect(state_bytes).not_to include(spelled)
    end
  end

  it "holds no decoy value after a git show of a committed then deleted credential file" do
    decoy = File.read(decoy_fixture).split("=", 2).last.strip
    identity = %w[-c user.name=t -c user.email=t@example.com -c commit.gpgsign=false]
    FileUtils.cp(decoy_fixture, File.join(@root, ".env"))
    SeedRepo.git(@root, "init", "-q")
    SeedRepo.git(@root, "add", ".env")
    SeedRepo.git(@root, *identity, "commit", "-q", "-m", "add")
    SeedRepo.git(@root, "rm", "-q", ".env")
    SeedRepo.git(@root, *identity, "commit", "-q", "-m", "remove")
    bytes, records = session_after(["git show HEAD~1:.env"])

    expect(result_contents(records)).to all(include("<redacted:1>"))
    expect(bytes).not_to include(decoy)
    expect(bytes).not_to include(Base64.strict_encode64(decoy))
  end

  # A future fix flips this group on purpose.
  describe "known limit: reshaped output" do
    {
      reversed: "printenv CANARY_API_TOKEN | rev",
      rot13: "printenv CANARY_API_TOKEN | tr 'A-Za-z' 'N-ZA-Mn-za-m'"
    }.each do |name, command|
      it "lets the #{name} spelling reach the session file" do
        bytes, = session_after([command])

        expect(bytes).to include(reshaped(canary).fetch(name))
      end
    end

    it "lets a secret split across 2 lines reach the session file in both halves" do
      bytes, = session_after(["printenv CANARY_API_TOKEN | fold -w17"])

      expect(bytes).to include(canary[0, 17]).and include(canary[17..])
    end

    context "with a 13 byte secret" do
      let(:lent) { "notreal-moss1" }

      it "lets its base64 spelling reach the session file, as it is too short to look like a credential" do
        bytes, = session_after(["printenv CANARY_API_TOKEN | base64 -w0"])

        expect(bytes).to include(Base64.strict_encode64("#{lent}\n"))
      end
    end
  end
end
