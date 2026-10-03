# frozen_string_literal: true

require "open3"
require "timeout"

# A pass takes no model flags, so it must review on the backend its session recorded; the chat runs
# on a model other than the default so a pass that lost the header's model cannot pass by accident.
RSpec.describe "the journal passes over a recorded session", :e2e do
  skill = <<~MD
    ---
    description: Ask a one-line question
    ---
    Answer the request in one short sentence. Do not call any tools.
  MD
  flags = %w[--provider ollama --model lfm2.5:latest --num-batch 1024 --seed 1 --temperature 0 --no-nvim].freeze

  once(:journey) do
    E2E::Cassette.serve("session_passes") do |upstream, _cassette|
      sandbox = E2E::Sandbox.create(files: { ".lain/skills/ask-lfm/skill.md" => skill })
      session = record_session(sandbox, upstream, flags)
      runs = %w[consolidate improve].to_h { |pass| [pass, run_pass(sandbox, upstream, pass, session)] }
      { header: header_of(session), runs: }
    end
  end

  def record_session(sandbox, upstream, flags)
    chat = E2E::PlainChat.start(sandbox, upstream.url, *flags)
    chat.type("@dev[/ask-lfm] What colour is a clear daytime sky?")
    chat.session.wait_for("message", timeout: patience) { |record| record["kind"] == "message" }
    chat.quit
    paths = Dir.glob(sandbox.state_home.join("lain", "sessions", "*", "*.ndjson").to_s)
    raise "expected exactly 1 session file, found #{paths.inspect}" unless paths.size == 1

    paths.first
  end

  def header_of(session) = JSON.parse(File.foreach(session).first)

  def run_pass(sandbox, upstream, pass, session)
    before = chat_bodies(upstream).size
    out, err, status = Timeout.timeout(patience * 2) do
      Open3.capture3(sandbox.env, E2E::PlainChat::EXE, pass, session,
                     chdir: sandbox.project.to_s, unsetenv_others: true)
    end
    { status:, output: "#{out}#{err}", bodies: chat_bodies(upstream)[before..] }
  end

  def patience = E2E::Cassette.recording? ? 300 : 30

  def chat_bodies(upstream)
    upstream.requests.select { |request| request[:method] == "POST" && request[:path] == "/api/chat" }
            .map { |request| request[:body] }
  end

  it "records the session on a model that is not the default" do
    expect(journey.fetch(:header)).to include("model" => "lfm2.5:latest", "num_batch" => 1024)
    expect(journey.fetch(:header).fetch("model")).not_to eq(Lain::Provider::Ollama::DEFAULT_MODEL)
  end

  %w[consolidate improve].each do |pass|
    it "runs #{pass} on the model and num_batch the session header recorded" do
      run = journey.fetch(:runs).fetch(pass)
      header = journey.fetch(:header)

      expect(run.fetch(:status).exitstatus).to eq(0), run.fetch(:output)
      expect(run.fetch(:bodies)).not_to be_empty
      expect(run.fetch(:bodies).map { |body| body["model"] }).to all(eq(header.fetch("model")))
      expect(run.fetch(:bodies).map { |body| body.dig("options", "num_batch") }).to all(eq(header.fetch("num_batch")))
    end
  end
end
