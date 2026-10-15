# frozen_string_literal: true

require "stringio"
require "tmpdir"

# `auto` approval on the path a real chat takes: {Lain::CLI::Wiring} builds the
# board, the board builds the judge-first ladder, and the judge asks the
# `auto_approver` role through the run's own role-spawn seam. Only the provider
# is canned, so the judge's answer is a child's reply rather than a stub.
RSpec.describe "auto approval asks the judge before a human", :seam do
  around do |example|
    Dir.mktmpdir("lain-judged-approval") do |dir|
      @state = File.realpath(dir)
      example.run
    end
  end

  let(:journal_io) { StringIO.new }
  let(:chronicle) do
    Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io), journal_path: "judged-approval.ndjson")
  end
  let(:provider) do
    Lain::Provider::Mock.new(responses: [
                               tool_response(["tu_1", "bash", { "command" => "rm -rf build" }]),
                               text_response("DEFER"),
                               text_response("settled")
                             ])
  end
  let(:backend) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:, **)
        super(options, **)
        @mock = mock
      end

      def provider(**) = @mock
    end.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: provider, root: @state)
  end
  let(:wiring) do
    Lain::CLI::Wiring.new(options: { grace: 5, approval: "auto" }, chronicle:,
                          status_feed: instance_double(Lain::StatusFeed, bind_store: nil),
                          paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }),
                          project: Lain::Project.new(root: @state, cwd: @state, kind: :project, detected_by: :flag))
  end

  def escalations = Lain::Journal.records(journal_io.string.lines, type: "escalation").to_a

  it "parks a gated command the judge defers, for the human to decide" do
    recorder, session = wiring.run_state(nil)
    agent = wiring.wire_agent(channel: Lain::Channel.new, recorder:, session:, backend:)

    pending = Sync do |task|
      asked = task.async { agent.ask("clean the build") }
      parked = task.with_timeout(5) { wiring.approvals.dequeue }
      parked.deny(surface: "tty")
      task.with_timeout(5) { asked.wait }
      parked
    end

    expect(pending).not_to be_humans_only
    expect(provider.requests[1].messages.to_s).to include("A tool call is requesting approval")
    expect(escalations).to include(a_hash_including("rung" => "auto", "verdict" => "abstain",
                                                    "reason" => Lain::Approval::Judged::DEFERRED))
  end
end
