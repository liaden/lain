# frozen_string_literal: true

require "async"
require "fileutils"
require "mixlib/shellout"
require "stringio"
require "tmpdir"

# A chat's children, and an out-of-chat run's, read and write through the same
# tool guard the parent does. Everything is real between the model and the
# file: the assembly {Lain::CLI::Wiring} or {Lain::CLI::EpicSubmit} builds, the
# spawn seam, the guard stack and the file on disk. Only the provider is
# scripted, and it is ONE provider, so parent and child draw their turns from a
# single script in the order the conversation reaches them.
RSpec.describe "A child's tools run behind its parent's guard", :seam do
  let(:secret) { "AKIAIOSFODNN7EXAMPLE" }
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
    Dir.mktmpdir("lain-child-guard") do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  attr_reader :root

  # An ORDINARY file by its path -- nothing about `creds.txt` is sensitive to
  # the path boundary -- holding a credential region only its bytes reveal.
  def secret_file
    File.join(root, "creds.txt").tap do |path|
      File.write(path, "harmless line\naws_access_key_id = #{secret}\ntail\n")
    end
  end

  def project = Lain::Project.new(root:, cwd: root, kind: :project, detected_by: :flag)

  def wired(chronicle: Lain::CLI::Chronicle::Null.new, notice: ->(_line) {}, **options)
    wiring = Lain::CLI::Wiring.new(options: { grace: 5, **options }, chronicle:, status_feed:, project:)
    recorder, session = wiring.run_state(nil)
    agent = wiring.wire_agent(channel: RecordingChannel.new, recorder:, session:, backend:, notice:)
    [wiring, agent]
  end

  # A spawn or an ask that parks for a human would otherwise hang the run until
  # the queue's own timeout; none of these should park at all.
  def within(seconds = 30, &) = Sync { |task| task.with_timeout(seconds, &) }

  def reads(id, path) = tool_response([id, "read_file", { "path" => path }])
  def writes(id, path, content) = tool_response([id, "write_file", { "path" => path, "content" => content }])
  def describing(constant) = "RSpec.describe #{constant} do\n  it { expect(1).to eq(1) }\nend\n"
  def spawns(id) = tool_response([id, "subagent", { "prompt" => "read the credentials file" }])

  def blocks_sent = provider.requests.flat_map { |request| request.messages.flat_map { |m| Array(m["content"]) } }

  # What the tool_result answering `id` carried, whichever request it rode in.
  def result_of(id)
    block = blocks_sent.grep(Hash).find { |sent| sent["type"] == "tool_result" && sent["tool_use_id"] == id }
    raise "no tool_result answered #{id}" unless block

    Array(block["content"]).map { |part| part.is_a?(Hash) ? part["text"] : part }.join("\n")
  end

  # The human at the approval surface, answering every park the same way and
  # keeping each one it saw, run as the sibling fiber a real surface is.
  def answering(task, wiring, answered, approve:)
    task.async do
      loop do
        pending = wiring.approvals.dequeue
        answered << pending
        approve ? pending.approve(surface: "spec") : pending.deny(surface: "spec")
      end
    end
  end

  def asking(wiring, agent, approve:)
    answered = []
    Sync do |task|
      surface = answering(task, wiring, answered, approve:)
      agent.ask("go")
    ensure
      surface&.stop
    end
    answered
  end

  describe "a chat-wired child" do
    it "has its read of an ordinary file masked, as the parent's would be" do
      path = secret_file
      script.push(spawns("tu_spawn"), reads("tu_child", path), text_response("child done"),
                  text_response("parent done"))
      wiring, agent = wired

      asked = asking(wiring, agent, approve: false)

      expect(asked.map(&:tool)).to eq(["read_file"])
      expect(result_of("tu_child")).to include("<redacted:1>").and include("harmless line")
      expect(result_of("tu_child")).not_to include(secret)
    end

    # The run has ONE region ledger, and the child's guard releases into it:
    # the parent's approval is the answer the child's read finds, so nobody is
    # asked twice about the same bytes.
    it "shares one region ledger with its parent, so one approval covers both reads" do
      path = secret_file
      script.push(reads("tu_parent", path), spawns("tu_spawn"), reads("tu_child", path),
                  text_response("child done"), text_response("parent done"))
      wiring, agent = wired

      asked = asking(wiring, agent, approve: true)

      expect(asked.size).to eq(1)
      expect(result_of("tu_parent")).to include(secret)
      expect(result_of("tu_child")).to include(secret)
    end
  end

  # The test layout, held in a live chat for the parent and its children alike.
  describe "a chat over a project that declares the rspec layout" do
    let(:sibling) { "spec/unit/models/order_extra_spec.rb" }

    before do
      FileUtils.cp_r("spec/fixtures/projects/layout_mini/.", root)
      FileUtils.mkdir_p(File.join(root, "spec", "unit", "models"))
    end

    it "refuses a dev child's split sibling, naming the path its subject's test belongs at, and writes nothing" do
      script.push(writes("tu_child", File.join(root, sibling), describing("Order")), text_response("child done"))
      wiring, = wired

      within { wiring.role_spawn.call(:dev, :fresh, "write the spec") }

      expect(result_of("tu_child")).to include("refused", "spec/unit/models/order_spec.rb")
      expect(File.exist?(File.join(root, sibling))).to be(false)
    end

    it "writes the parent's test that mirrors its source, untouched" do
      script.push(writes("tu_parent", "spec/unit/models/order_spec.rb", describing("Order")),
                  text_response("parent done"))
      _, agent = wired

      within { agent.ask("write the spec") }

      expect(result_of("tu_parent")).to start_with("wrote")
      expect(File.read(File.join(root, "spec/unit/models/order_spec.rb"))).to eq(describing("Order"))
    end
  end

  # Under `--isolation worktree` a child writes in a checkout of its own, outside
  # the project root. The layout is repo-relative, so the write is held there,
  # against the checkout's own sources.
  describe "a dev child leased into a worktree of its own" do
    around do |example|
      Dir.mktmpdir("lain-child-guard-state") do |state|
        FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", root)
        FileUtils.cp_r("spec/fixtures/projects/layout_mini/.", root)
        git("add", "-A")
        git("commit", "-q", "-m", "the layout")
        git("switch", "-q", "-c", "feat")
        with_env("XDG_STATE_HOME" => File.realpath(state)) do
          trust_project(root)
          Dir.chdir(root) { example.run }
        end
      end
    end

    # Scrubbed as the subject scrubs, so a pre-commit hook's GIT_INDEX_FILE never
    # points these at lain's own index.
    def git(*args)
      Mixlib::ShellOut.new("git", "-C", root, *args, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
                      .run_command.error!
    end

    it "refuses a split sibling written in its checkout, naming the path its subject's test belongs at" do
      script.push(writes("tu_child", "spec/unit/models/order_extra_spec.rb", describing("Order")),
                  text_response("child done"))
      wiring, = wired(isolation: "worktree")

      within(60) { wiring.role_spawn.call(:dev, :fresh, "write the spec") }

      expect(result_of("tu_child")).to include("refused", "spec/unit/models/order_spec.rb")
    end
  end

  # Enforcement is opt-in: no `[tests]` table, no refusal, and the run says
  # once that it has none.
  describe "a chat over a project that declares no layout" do
    let(:journal_io) { StringIO.new }

    before { FileUtils.mkdir_p(File.join(root, "spec")) }

    def absences = Lain::Journal.records(journal_io.string.lines, type: "test_layout_absent").to_a

    it "refuses neither of two test writes, and journals one absence" do
      script.push(writes("tu_1", "spec/a_spec.rb", describing("A")), writes("tu_2", "spec/b_spec.rb", describing("B")),
                  text_response("done"))
      # A real chronicle, so what the run journaled can be read back. The path
      # only names where a response spool would go; the scripted provider
      # opens none.
      _, agent = wired(chronicle: Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io),
                                                           journal_path: File.join(root, "session.ndjson")))

      within { agent.ask("write two specs") }

      expect([result_of("tu_1"), result_of("tu_2")]).to all(start_with("wrote"))
      expect(absences.size).to eq(1)
    end
  end

  # Out of chat there is no board to borrow and nobody at a surface, so the
  # command builds its own guard, and a region nobody can release stays masked.
  describe "an out-of-chat child" do
    let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(root, "state"), "HOME" => root }) }
    let(:gates) { Lain::Epic::STAGES.to_h { |stage| [stage, "hands_off"] }.merge("research" => "adjudicated") }
    let(:config) { Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg, gates:)) }

    def home = Lain::Epic::Home.resolve(config:, paths:, root:, slug: "alpha")

    # The three things the adjudication pair reads off a backend.
    def adjudicating_backend
      Data.define(:provider, :context, :slots)
          .new(provider:, context: Lain::Context.new(model: "judge", max_tokens: 256),
               slots: Lain::Prompt::Slots.load(root:))
    end

    before do
      home.research.write("the research, such as it is\n")
      home.write_epic(Lain::Epic::Graph.new(issues: [Lain::Epic::Issue.new(id: "a", title: "the a issue")]))
    end

    it "has the adjudicator's read masked by a guard lain epic submit builds for itself" do
      path = secret_file
      script.push(text_response("the evidence, gathered"), reads("tu_judge", path), text_response("APPROVE"))
      submit = Lain::CLI::EpicSubmit.from_options({}, input: instance_double(IO, tty?: true, gets: "y\n"),
                                                      output: StringIO.new, root:, paths:, config:,
                                                      backend: -> { adjudicating_backend })

      submit.submit("research")

      expect(result_of("tu_judge")).to include("<redacted:1>")
      expect(result_of("tu_judge")).not_to include(secret)
    end
  end
end
