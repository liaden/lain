# frozen_string_literal: true

require "tmpdir"

# A real `lain chat` replaying model turns recorded from a local ollama: what reaches the wire when
# a parent on one model reads a file and a skill child on another model answers.
RSpec.describe "the wire contract of a recorded plain chat", :e2e do
  notes = "# Notes\n\nThe build bell rings twice when the nightly run passes.\n"
  skill = <<~MD
    ---
    description: Ask a second model a one-line question
    model: lfm2.5:latest
    ---
    Answer the request in one short sentence. Do not call any tools.
  MD
  flags = %w[--provider ollama --model qwen3:4b --num-batch 1024 --seed 1 --temperature 0 --no-nvim].freeze

  once(:journey) do
    E2E::Cassette.serve("wire_contract") do |upstream, cassette|
      sandbox = E2E::Sandbox.create(files: { "NOTES.md" => notes, ".lain/skills/ask-lfm/skill.md" => skill })
      parent_count = drive(E2E::PlainChat.start(sandbox, upstream.url, *flags), upstream)
      { cassette:, parent_count:, bodies: chats(upstream.requests).map { |request| request[:body] } }
    end
  end

  def drive(chat, upstream)
    chat.type("Use read_file to read NOTES.md, then tell me in one sentence what it says.")
    chat.session.wait_for("turn_usage", timeout: patience) { |record| record["stop_reason"] == "end_turn" }
    parent_count = chats(upstream.requests).size
    chat.type("@dev[/ask-lfm] What colour is a clear daytime sky?")
    chat.session.wait_for("message", timeout: patience) { |record| record["kind"] == "message" }
    chat.quit
    parent_count
  end

  def patience = E2E::Cassette.recording? ? 300 : 15

  def chats(requests) = requests.select { |request| request[:method] == "POST" && request[:path] == "/api/chat" }

  def bodies = journey.fetch(:bodies)

  it "sends the launched options on every model call" do
    expect(bodies).not_to be_empty
    expect(bodies.map { |body| body.dig("options", "num_predict") }).to all(be_an(Integer))
    expect(bodies.map { |body| body.dig("options", "num_batch") }).to all(eq(1024))
  end

  it "names the parent's model on the parent's calls and the skill's model on the child's" do
    parent, child = bodies.partition.with_index { |_, index| index < journey.fetch(:parent_count) }

    expect(parent).not_to be_empty
    expect(child).not_to be_empty
    expect(parent.map { |body| body["model"] }).to all(eq("qwen3:4b"))
    expect(child.map { |body| body["model"] }).to all(eq("lfm2.5:latest"))
  end

  it "replays offline, playing every recorded call with no mismatch" do
    expect(journey.fetch(:cassette).mismatches).to be_empty
    expect(journey.fetch(:cassette).unplayed).to be_empty
  end
end

RSpec.describe E2E::Cassette, :e2e do
  def chat_request(tools:, last: { "role" => "user", "content" => "hello" })
    body = { "model" => "qwen3:4b", "messages" => [last], "options" => { "num_predict" => 64 },
             "tools" => tools.map { |name| { "type" => "function", "function" => { "name" => name } } } }
    E2E::Upstream::Request.new(verb: "POST", path: "/api/chat", body:)
  end

  def cassette_holding(request, dir)
    interaction = {
      "request" => { "method" => "post", "uri" => "http://localhost:11434/api/chat",
                     "body" => { "encoding" => "UTF-8",
                                 "string" => JSON.generate(E2E::Cassette::Fingerprint.of(request.body).to_h) } },
      "response" => { "status" => { "code" => 200, "message" => "OK" },
                      "body" => { "encoding" => "UTF-8", "string" => "{\"done\":true}\n" } }
    }
    File.join(dir, "stale.yml").tap do |path|
      File.write(path, YAML.dump("http_interactions" => [interaction], "recorded_with" => "VCR 6.4.0"))
    end
  end

  it "fails a replay whose recording offered a tool the request does not, naming the field and the fix" do
    Dir.mktmpdir do |dir|
      replay = E2E::Cassette::Replay.load(cassette_holding(chat_request(tools: %w[read_file grep]), dir))

      reply = replay.call(chat_request(tools: %w[read_file]))

      expect(reply.lines).to eq(["{\"done\":true}\n"])
      expect(replay.mismatches).to contain_exactly(include(index: 0, field: :tools))
      expect { replay.finish }.to raise_error(/tools.*LAIN_RECORD=ollama/m)
    end
  end

  it "names the drift and the fix even when the drift stalls the journey" do
    Dir.mktmpdir do |dir|
      stub_const("E2E::Cassette::DIR", dir)
      cassette_holding(chat_request(tools: %w[read_file grep]), dir)
      File.rename(File.join(dir, "stale.yml"), File.join(dir, "stalled.yml"))

      expect do
        described_class.serve("stalled") do |_upstream, cassette|
          cassette.call(chat_request(tools: %w[read_file]))
          raise "a turn_usage record never held within 15s"
        end
      end.to raise_error(described_class::Stale, /tools.*LAIN_RECORD=ollama/m) { |error|
        expect(error.cause.message).to start_with("a turn_usage record never held")
      }
    end
  end

  it "writes nothing when a recording fails, and says the recording failed" do
    Dir.mktmpdir do |dir|
      stub_const("E2E::Cassette::DIR", dir)
      allow(VcrRecording).to receive(:requested).and_return("ollama")

      expect { described_class.serve("never_finished") { raise "a turn_usage record never held" } }
        .to raise_error(described_class::Unrecorded, /never_finished/) { |error|
          expect(error.cause.message).to eq("a turn_usage record never held")
        }
      expect(Dir.children(dir)).to be_empty
    end
  end

  it "records a real /api/show the first time a journey asks for one", :ollama do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "probes.yml")
      show = E2E::Upstream::Request.new(verb: "POST", path: "/api/show", body: { "model" => "qwen3:4b" })

      recorded = described_class::Probes.new(path, recording: true).call(show)
      replayed = described_class::Probes.new(path, recording: false).call(show)

      expect(JSON.parse(recorded.lines.join)).to include("model_info")
      expect(replayed).to eq(recorded)
    end
  end

  it "says how to record a cassette that does not exist" do
    allow(VcrRecording).to receive(:requested).and_return(nil)

    expect { described_class.for("absent") }.to raise_error(/LAIN_RECORD=ollama/)
  end
end
