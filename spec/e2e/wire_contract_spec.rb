# frozen_string_literal: true

require "fileutils"
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
    E2E::Cassette.serve("wire_contract") do |upstream, _cassette|
      sandbox = E2E::Sandbox.create(files: { "NOTES.md" => notes, ".lain/skills/ask-lfm/skill.md" => skill })
      parent_count = drive(E2E::PlainChat.start(sandbox, upstream.url, *flags), upstream)
      { parent_count:, bodies: chats(upstream.requests).map { |request| request[:body] } }
    end
  end

  def drive(chat, upstream)
    first = "Use read_file to read NOTES.md, then tell me in one sentence what it says."
    chat.type(first)
    chat.session.wait_for("turn_usage", timeout: patience) { |record| record["stop_reason"] == "end_turn" }
    # The next line is typed at you>, never while the first run is still settling.
    chat.await_prompt(since: chat.screen.rindex(first) + first.size)
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
end

RSpec.describe E2E::Cassette, :e2e do
  def chat_request(tools:, last: { "role" => "user", "content" => "hello" })
    body = { "model" => "qwen3:4b", "messages" => [last], "options" => { "num_predict" => 64 },
             "tools" => tools.map { |name| { "type" => "function", "function" => { "name" => name } } } }
    E2E::Upstream::Request.new(verb: "POST", path: "/api/chat", body:)
  end

  def cassette_holding(request, dir, response: "{\"done\":true}\n")
    interaction = {
      "request" => { "method" => "post", "uri" => "http://localhost:11434/api/chat",
                     "body" => { "encoding" => "UTF-8",
                                 "string" => JSON.generate(E2E::Cassette::Fingerprint.of(request.body).to_h) } },
      "response" => { "status" => { "code" => 200, "message" => "OK" },
                      "body" => { "encoding" => "UTF-8", "string" => response } }
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

  describe "a request naming a sandbox" do
    def fingerprint(content)
      last = { "role" => "user", "content" => content }
      described_class::Fingerprint.of(chat_request(tools: %w[bash], last:).body)
    end

    def lease_in(sandbox)
      "project root: #{sandbox.dir}/state/lain/worktrees/#{Lain::Paths.new.project_hash(sandbox.project.to_s)}/x"
    end

    # A journey's sandboxes are reaped after each example, so the next run's are a later lifetime.
    def in_later_sandbox
      E2E::Sandbox.reap_all!
      yield E2E::Sandbox.create
    end

    it "fingerprints alike across sandbox lifetimes when only the sandbox's root differs" do
      earlier = fingerprint(lease_in(E2E::Sandbox.create))

      expect(in_later_sandbox { |sandbox| fingerprint(lease_in(sandbox)) }).to eq(earlier)
    end

    it "fingerprints apart when anything else differs" do
      earlier = fingerprint(lease_in(E2E::Sandbox.create))

      expect(in_later_sandbox { |sandbox| fingerprint("#{lease_in(sandbox)} and more") }).not_to eq(earlier)
    end

    it "keeps 2 projects that share a state dir apart" do
      first = E2E::Sandbox.create
      second = E2E::Sandbox.create(share_state_with: first, project: "proj-b")

      expect(fingerprint(lease_in(first))).not_to eq(fingerprint(lease_in(second)))
    end

    it "numbers a sandbox from those made since its journey's cassette began serving" do
      E2E::Sandbox.create
      Dir.mktmpdir do |dir|
        stub_const("E2E::Cassette::DIR", dir)
        recorded = chat_request(tools: %w[read_file])
        File.rename(cassette_holding(recorded, dir), File.join(dir, "numbered.yml"))

        seen = described_class.serve("numbered") do |_upstream, cassette|
          cassette.call(recorded)
          fingerprint("cwd: #{E2E::Sandbox.create.project}").last_message.last
        end

        expect(seen).to eq("cwd: <SANDBOX1>/proj")
      end
    end

    it "forgets a sandbox once it is reaped" do
      E2E::Sandbox.create.reap

      expect(fingerprint("cwd: #{E2E::Sandbox.create.project}").last_message.last).to eq("cwd: <SANDBOX1>/proj")
    end

    def leased(sandbox, id)
      FileUtils.mkdir_p(File.join(lease_in(sandbox).delete_prefix("project root: ").delete_suffix("/x"), id)).first
    end

    it "names a lease checkout by its number, so a lease id that moves between runs fingerprints alike" do
      earlier = fingerprint("wrote 2 bytes to #{leased(E2E::Sandbox.create, "bf376f3105f8")}/hello.txt")

      later = in_later_sandbox do |sandbox|
        fingerprint("wrote 2 bytes to #{leased(sandbox, "0788da1adf77")}/hello.txt")
      end

      expect(later).to eq(earlier)
      expect(later.last_message.last).to eq("wrote 2 bytes to <LEASE1>/hello.txt")
    end

    it "records a reply that names a sandbox with its placeholder, and hands the live chat the real path" do
      sandbox = E2E::Sandbox.create
      said = "{\"message\":{\"content\":\"look in #{sandbox.project}\"},\"done\":true}\n"
      request = chat_request(tools: %w[bash])
      forwarded = described_class::Interaction.new(verb: "post", path: "/api/chat", request: {}, status: 200,
                                                   message: "OK", response: said, recorded_at: "now")
      allow(described_class::Ollama).to receive(:forward).and_return(forwarded)
      Dir.mktmpdir do |dir|
        recorder = described_class::Recorder.new(File.join(dir, "named.yml"))

        expect(recorder.call(request).lines.join).to include("look in #{sandbox.project}")
        recorder.save
        stored = described_class::Tape.read(File.join(dir, "named.yml")).sole.response
        expect(stored).to include("look in <SANDBOX1>/proj")
      end
    end

    it "replays a recorded placeholder as the live sandbox's path" do
      Dir.mktmpdir do |dir|
        request = chat_request(tools: %w[read_file grep])
        recorded = "{\"cwd\":\"<SANDBOX1>/proj\"}\n"
        replay = described_class::Replay.load(cassette_holding(request, dir, response: recorded))
        sandbox = E2E::Sandbox.create

        expect(replay.call(request).lines.join).to include("#{sandbox.dir}/proj")
      end
    end

    it "keeps 2 live sandboxes apart" do
      first = E2E::Sandbox.create
      second = E2E::Sandbox.create

      expect(fingerprint("cwd: #{first.project}")).not_to eq(fingerprint("cwd: #{second.project}"))
    end
  end

  it "says how to record a cassette that does not exist" do
    allow(VcrRecording).to receive(:requested).and_return(nil)

    expect { described_class.for("absent") }.to raise_error(/LAIN_RECORD=ollama/)
  end
end
