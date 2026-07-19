# frozen_string_literal: true

require "json"

RSpec.describe Lain::Middleware::RefuseSecretWrites do
  subject(:middleware) { described_class.new(journal:) }

  let(:journal) { RecordingChannel.new }

  def tool_call(name: "memory_write", input: {})
    Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name:, input:)
  end

  # Runs `effect` through the middleware. Returns [resulting_env,
  # downstream_was_called] -- downstream's own env transformation (merging a
  # canned ok Result) is how a refusal's "never called" is told apart from a
  # pass-through that merely produced the same-shaped env by coincidence.
  def run(effect, middleware: self.middleware)
    called = false
    env = middleware.call({ effect:, context: nil }) do |inner|
      called = true
      inner.merge(result: Lain::Tool::Result.ok("wrote"))
    end
    [env, called]
  end

  describe "middleware citizenship" do
    it "is frozen -- stateless beyond its injected journal and oracle" do
      expect(middleware).to be_frozen
    end

    it "defaults journal and oracle so bare construction needs no guard" do
      benign = tool_call(input: { "id" => "a", "description" => "b", "body" => "c" })
      bare_call = lambda do
        described_class.new.call({ effect: benign, context: nil }) { |env| env.merge(result: Lain::Tool::Result.ok("x")) }
      end
      expect(&bare_call).not_to raise_error
    end
  end

  describe "a secret never reaches the index" do
    it "skips downstream, returns an error Result, and journals write_refused without the secret bytes" do
      secret = "sk-#{"a" * 20}"
      env, called = run(tool_call(input: { "id" => "creds", "description" => "oops", "body" => secret }))

      expect(called).to be(false)
      expect(env.fetch(:result)).to be_a(Lain::Tool::Result)
      expect(env.fetch(:result).error?).to be(true)
      expect(env.fetch(:result).content).not_to include(secret)

      expect(journal.events.size).to eq(1)
      refusal = journal.events.first
      expect(refusal).to be_a(Lain::Telemetry::WriteRefused)
      expect(refusal.tool_use_id).to eq("tu_1")
      expect(refusal.pattern).to eq("openai-style api key")
      expect(refusal.pattern).not_to include(secret)
      expect(JSON.generate(refusal.to_journal)).not_to include(secret)
    end
  end

  describe "ordinary writes pass through untouched" do
    it "lets a benign memory_write proceed, with nothing journaled" do
      benign = tool_call(input: { "id" => "dosage", "description" => "Adult dosage", "body" => "500mg twice daily" })
      env, called = run(benign)

      expect(called).to be(true)
      expect(env.fetch(:result).error?).to be(false)
      expect(journal.events).to be_empty
    end
  end

  describe "only write-shaped effects are guarded" do
    it "passes a non-memory_write effect through even when its input looks secret-ish" do
      secret_ish = tool_call(name: "bash", input: { "command" => "echo sk-#{"a" * 20}" })
      env, called = run(secret_ish)

      expect(called).to be(true)
      expect(env.fetch(:result).error?).to be(false)
      expect(journal.events).to be_empty
    end

    it "passes a read_file effect through even when its input looks secret-ish" do
      secret_ish = tool_call(name: "read_file", input: { "path" => "/etc/AKIA#{"A" * 16}.pem" })
      _env, called = run(secret_ish)

      expect(called).to be(true)
      expect(journal.events).to be_empty
    end
  end

  describe "deterministic pattern shapes" do
    {
      "sk-#{"a" * 20}" => "openai-style api key",
      "AKIA#{"A" * 16}" => "aws access key id",
      "-----BEGIN RSA PRIVATE KEY-----\nMIIB...\n-----END RSA PRIVATE KEY-----" => "pem private key block",
      "password: hunter2" => "credential assignment"
    }.each do |sample, pattern_name|
      it "names #{pattern_name.inspect} for a refused body shaped like it" do
        _env, called = run(tool_call(input: { "id" => "x", "description" => "y", "body" => sample }))

        expect(called).to be(false)
        expect(journal.events.first.pattern).to eq(pattern_name)
      end
    end

    # The reviewer's false-positive probe (.probe-T7-patterns.rb): "sk-"
    # embedded in a hyphenated word ("ask-someone...") satisfied the unanchored
    # key regex, so benign prose was refused under a pattern name it never
    # honestly matched. The key shape must stand alone -- nothing word-like or
    # hyphenated may run into the "sk-".
    ["the ski trip was great, we should do it again ask-someone-to-help-with-planning-next-year",
     "this-is-just-a-long-hyphenated-slug-ask-for-directions-please-thanks-a-lot"].each do |prose|
      it "does not mistake #{prose[0, 44].inspect}... for an api key" do
        _env, called = run(tool_call(input: { "id" => "notes", "description" => "prose", "body" => prose }))

        expect(called).to be(true)
        expect(journal.events).to be_empty
      end
    end

    it "still refuses a real-shaped sk- key at start-of-string, mid-sentence, and after punctuation" do
      ["sk-#{"a" * 20}", "my key is sk-#{"a" * 20}", "KEY=sk-#{"a" * 20}"].each do |body|
        refusals = RecordingChannel.new
        guard = described_class.new(journal: refusals)
        _env, called = run(tool_call(input: { "id" => "x", "description" => "y", "body" => body }),
                           middleware: guard)

        expect(called).to be(false)
        expect(refusals.events.first.pattern).to eq("openai-style api key")
      end
    end
  end

  describe "the injectable predicate seam" do
    it "is a Null Object by default: never flags input on its own" do
      benign = tool_call(input: { "id" => "a", "description" => "b", "body" => "nothing secret here" })
      _env, called = run(benign)
      expect(called).to be(true)
    end

    it "is swappable: an injected oracle can refuse input no deterministic pattern matches" do
      oracle = Class.new do
        def secret?(_input) = true
      end.new
      guarded = described_class.new(journal:, oracle:)

      benign_shaped = tool_call(input: { "id" => "a", "description" => "b", "body" => "looks fine to a regex" })
      env, called = run(benign_shaped, middleware: guarded)

      expect(called).to be(false)
      expect(env.fetch(:result).error?).to be(true)
      expect(journal.events.size).to eq(1)
      expect(journal.events.first.pattern).to eq(Lain::Middleware::RefuseSecretWrites::ORACLE_MATCH)
    end
  end

  describe "the memory-save oracle wired through the seam (T4)" do
    it "refuses through the SAME seam a plain oracle does, for a write the regex never catches" do
      gate = Lain::Oracle::MemorySave::Gate.new
      guarded = described_class.new(journal:, oracle: gate)
      opaque = ("a".."z").cycle.first(40).join

      env, called = run(tool_call(input: { "id" => "x", "description" => "y", "body" => opaque }),
                        middleware: guarded)

      expect(called).to be(false)
      expect(env.fetch(:result).error?).to be(true)
      expect(journal.events.size).to eq(1)
      expect(journal.events.first.pattern).to eq(described_class::ORACLE_MATCH)
    end

    it "lets a write both the regex and the oracle judge safe proceed" do
      gate = Lain::Oracle::MemorySave::Gate.new
      guarded = described_class.new(journal:, oracle: gate)
      benign = tool_call(input: { "id" => "dosage", "description" => "Adult dosage", "body" => "500mg twice daily" })

      env, called = run(benign, middleware: guarded)

      expect(called).to be(true)
      expect(env.fetch(:result).error?).to be(false)
      expect(journal.events).to be_empty
    end
  end

  describe "in an Agent's tool phase" do
    it "keeps the real recorder untouched: the refused write never lands in the Memory::Index" do
      recorder = Lain::Memory::Recorder.new
      toolset = Lain::Toolset.new([Lain::Tools::MemoryWrite.new(recorder:)])
      secret = "sk-#{"a" * 20}"

      creds_write = ["tu_1", "memory_write", { "id" => "creds", "description" => "oops", "body" => secret }]
      agent = Lain::Agent.new(
        provider: Lain::Provider::Mock.new(responses: [tool_response(creds_write), text_response("done")]),
        toolset:,
        context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024),
        tool_middleware: Lain::Middleware::Stack.new([middleware])
      )

      agent.ask("please remember this")

      expect(recorder.root).to be_nil
      expect(journal.events.size).to eq(1)
      expect(journal.events.first).to be_a(Lain::Telemetry::WriteRefused)
    end
  end
end
