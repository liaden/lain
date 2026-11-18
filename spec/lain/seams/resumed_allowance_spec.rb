# frozen_string_literal: true

require "json"
require "tmpdir"

# The real Wiring writes a granted allowance into a real session file, and the real Resume and
# Wiring read it back; only the ollama socket is stubbed.
RSpec.describe "a resumed chat keeps the skill's allowance", :seam do
  let(:model) { "qwen3:4b" }
  let(:state_home) { File.realpath(Dir.mktmpdir("resumed-allowance-state")) }
  let(:project_dir) { File.realpath(Dir.mktmpdir("resumed-allowance-project")) }
  let(:paths) { Lain::Paths.new(env: SpecHome.env({ "XDG_STATE_HOME" => state_home })) }
  let(:project) { throwaway_project(project_dir) }

  after { FileUtils.rm_rf([state_home, project_dir]) }

  before do
    stub_request(:get, %r{/api/ps}).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: JSON.generate("models" => [{ "name" => model, "model" => model, "context_length" => 8192 }])
    )
    body = { "model" => model, "message" => { "role" => "assistant", "content" => "settled" }, "done" => true,
             "done_reason" => "stop", "prompt_eval_count" => 10, "eval_count" => 1 }
    stub_request(:post, %r{/api/chat}).to_return(status: 200, headers: { "Content-Type" => "application/x-ndjson" },
                                                 body: "#{JSON.generate(body)}\n")
  end

  def backend
    provider = Lain::Provider::Ollama.new(config: zero_retry_config)
    Class.new(Lain::CLI::Backend) { define_method(:provider) { |**| provider } }
         .new({ provider: "ollama", model:, max_tokens: 64 }, root: project_dir)
  end

  def chat(path, resumed: nil)
    journal = Lain::Journal.new(io: File.open(path, "ab"), owns_io: true, fsync: true, path:)
    chronicle = Lain::CLI::Chronicle.new(journal:, journal_path: path)
    wiring = Lain::CLI::Wiring.new(human: Lain::CLI::Human.new(kind: :terminal),
                                   options: { grace: 5 }, chronicle:, project:,
                                   status_feed: instance_double(Lain::StatusFeed, bind_store: nil))
    recorder, session = resumed ? [resumed.recorder, resumed.session] : wiring.run_state(nil)
    agent = wiring.wire_agent(channel: Lain::Channel.new, recorder:, session:, backend:, resumed:)
    [agent, chronicle, journal]
  end

  def session_path(name)
    File.join(paths.filing_dir(root: project.root), name).tap { FileUtils.mkdir_p(File.dirname(_1)) }
  end

  def resume(file)
    Lain::CLI::Resume.new(paths:, project:).call(profile: Lain::CLI::RunProfile.from_options({}),
                                                 selector: File.basename(file))
  end

  def finish(agent, chronicle, journal)
    agent.ask("hello")
    chronicle.catch_up(agent.timeline)
    journal.close
  end

  def grants(file) = File.readlines(file).map { JSON.parse(_1) }.select { _1["type"] == "run_allowance" }

  it "seeds the resumed agent from the file, and journals the grant again in the new one" do
    first = session_path("20261104T000000-1.ndjson")
    agent, chronicle, journal = chat(first)
    agent.allow(Lain::Budget.ceilings(iterations: 103))
    finish(agent, chronicle, journal)

    second = session_path("20261104T000001-1.ndjson")
    resumed_agent, chronicle2, journal2 = chat(second, resumed: resume(first))
    finish(resumed_agent, chronicle2, journal2)

    expect(resumed_agent.allowed).to eq(103)
    expect(grants(second).map { _1["iterations"] }).to eq([103])
    expect(resume(second).allowance.iterations).to eq(103)
  end
end
