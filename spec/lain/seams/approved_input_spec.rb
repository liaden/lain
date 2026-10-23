# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# A configured tool member that replaces the call before the gate, as a user's
# config may: `merge` builds a fresh Hash, so only the effect's own freeze keeps
# the call that parks from being changed while a human looks at it.
module ApprovedInputSeam
  class Rewrite < Lain::Middleware::Base
    def call(env, &block)
      effect = env.fetch(:effect)
      downstream(env.merge(effect: effect.with(input: effect.input.merge("command" => "echo rewritten > out.txt"))),
                 &block)
    end
  end
end

RSpec.describe "a parked call runs the bytes the human was shown", :seam do
  around do |example|
    Dir.mktmpdir("lain-approved-input") do |dir|
      @state = File.realpath(dir)
      @cwd = File.join(@state, "proj")
      FileUtils.mkdir_p(@cwd)
      File.open(journal_path, "w") do |io|
        @journal_io = io
        example.run
      end
    end
  end

  let(:journal_path) { File.join(@state, "session.ndjson") }
  let(:journal_io) { @journal_io }
  let(:chronicle) { Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io), journal_path:) }
  let(:provider) do
    Lain::Provider::Mock.new(responses: [tool_response(["tu_1", "bash", { "command" => "echo asked > out.txt" }]),
                                         text_response("ok")])
  end
  let(:configured) do
    Lain::Config::Builder.evaluate("middleware { tool ApprovedInputSeam::Rewrite }\n", path: "/spec/config.rb")
                         .middleware
  end
  let(:backend) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:, configured:, **)
        super(options, **)
        @mock = mock
        @configured = configured
      end

      def provider(**) = @mock
      def middleware = @configured
    end.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: provider, configured:, root: @state)
  end
  let(:wiring) do
    Lain::CLI::Wiring.new(options: { grace: 5, approval: "ask" }, chronicle:,
                          status_feed: instance_double(Lain::StatusFeed, bind_store: nil),
                          paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }),
                          project: Lain::Project.new(root: @cwd, cwd: @cwd, kind: :project, detected_by: :flag))
  end

  def ran = File.read(File.join(@cwd, "out.txt"))

  def tampered(parked)
    parked.input["command"] = "echo tampered > out.txt"
    :written
  rescue FrozenError
    :refused
  end

  it "refuses a write to the parked input of a call a configured member replaced, and runs the replaced call" do
    recorder, session = wiring.run_state(nil)
    agent = wiring.wire_agent(channel: Lain::Channel.new, recorder:, session:, backend:)
    attempt = nil

    Sync do |task|
      asked = task.async { agent.ask("go") }
      parked = task.with_timeout(10) { wiring.approvals.dequeue }
      attempt = tampered(parked)
      parked.approve(surface: "tty", authority: :human)
      task.with_timeout(20) { asked.wait }
    end
    journal_io.flush

    expect([attempt, ran]).to eq([:refused, "rewritten\n"])
    expect(journal_records(File.readlines(journal_path), "approval_decision").map { _1["input_digest"] })
      .to eq([Lain::Canonical.digest({ "command" => "echo rewritten > out.txt" })])
  end
end
