# frozen_string_literal: true

# T4 (OR-3), second oracle arm: "worth remembering?" -- plugged into
# {Lain::Middleware::RefuseSecretWrites}'s existing `oracle:` seam via {Gate}.
# The live gate is SYNCHRONOUS (a memory_write cannot be un-written once
# indexed), so only the heuristic tier may ever back it in production; this
# spec pins the contentlessness floor it applies -- it is a floor, not a
# quality judgement, and not an OR-4 comparison baseline -- and the Gate
# adapter that exposes it through `#secret?`. The end-to-end wiring through
# RefuseSecretWrites itself is pinned in refuse_secret_writes_spec.rb.
RSpec.describe Lain::Oracle::MemorySave do
  describe ".heuristic (the live-path arm)" do
    it "scores ordinary content worth saving with no model call" do
      oracle = described_class.heuristic

      answer = Sync { oracle.ask(id: "x", description: "y", body: "500mg twice daily").await }

      expect(answer.worth_saving).to be(true)
      expect(oracle.model).to be_nil
      expect(oracle.usage).to eq({})
    end

    it "flags a blank body as not worth saving" do
      oracle = described_class.heuristic

      answer = Sync { oracle.ask(id: "x", description: "y", body: "   ").await }

      expect(answer.worth_saving).to be(false)
    end

    it "flags a body with no alphanumeric content at all as not worth saving" do
      oracle = described_class.heuristic

      answer = Sync { oracle.ask(id: "x", description: "y", body: "--- ... ---").await }

      expect(answer.worth_saving).to be(false)
    end

    # This example is the INVERSION of the original calibration, which pinned
    # any unbroken 24+-char run as not worth saving. That rule refused git
    # SHAs, UUIDs and tracking numbers -- the identifiers a later memory_read
    # exists to surface -- and the over-refusal is what blocked live wiring.
    it "saves an opaque, unbroken token: an identifier is content, not noise" do
      oracle = described_class.heuristic
      blob = ("a".."z").cycle.first(40).join

      answer = Sync { oracle.ask(id: "x", description: "y", body: blob).await }

      expect(answer.worth_saving).to be(true)
    end

    it "saves a 40-character hex commit SHA" do
      oracle = described_class.heuristic
      sha = "9d2c1f0a3b4e5d6c7f8091a2b3c4d5e6f7081920"

      answer = Sync { oracle.ask(id: "commit", description: "the fix", body: sha).await }

      expect(answer.worth_saving).to be(true)
    end

    it "saves a canonical UUID" do
      oracle = described_class.heuristic
      uuid = "f81d4fae-7dec-11d0-a765-00a0c91e6bf6"

      answer = Sync { oracle.ask(id: "run", description: "bench run id", body: uuid).await }

      expect(answer.worth_saving).to be(true)
    end

    # The heuristic is NOT a secret detector and must not pretend to be one:
    # credentials are refused by {Middleware::RefuseSecretWrites::PATTERNS},
    # which is where a named credential shape can be journaled honestly.
    it "does not claim to detect secrets -- an API-key body is left to the patterns" do
      oracle = described_class.heuristic
      key = "sk-#{"A" * 32}"

      answer = Sync { oracle.ask(id: "x", description: "y", body: key).await }

      named = Lain::Middleware::RefuseSecretWrites::PATTERNS.find { |_name, pattern| pattern.match?(key) }

      expect(answer.worth_saving).to be(true)
      expect(named.first).to eq("openai-style api key")
    end

    # `[[:alnum:]]` is Unicode-aware, and that is the ONLY reason a non-Latin
    # body saves. "Simplifying" it to /[a-zA-Z0-9]/ would silently refuse
    # every Japanese, Cyrillic or Greek write with a fully green suite, which
    # is why this example exists rather than being folded into the one above.
    it "saves a body with no Latin characters at all" do
      oracle = described_class.heuristic

      answer = Sync { oracle.ask(id: "x", description: "y", body: "一日二回、五百ミリグラム").await }

      expect(answer.worth_saving).to be(true)
    end

    it "is a Heuristic tier, matching the same interface a model tier would" do
      oracle = described_class.heuristic

      expect(oracle).to be_a(Lain::Oracle::Heuristic)
      expect(oracle.ask(id: "x", description: "y", body: "hi")).to be_a(Lain::Promise)
    end
  end

  describe Lain::Oracle::MemorySave::Gate do
    it "refuses (secret? true) when the wrapped tier judges the write not worth saving" do
      gate = described_class.new(tier: Lain::Oracle::MemorySave.heuristic)

      expect(gate.secret?({ "id" => "x", "description" => "y", "body" => "   " })).to be(true)
    end

    # The sharp edge: {Middleware::RefuseSecretWrites::GUARDED_TOOLS} sends
    # BOTH memory_write and improvement_write through this one seam, and an
    # improvement_write input has no `body` at all. Reading a missing key as
    # an empty body would refuse every improvement_write ever written.
    describe "an input it cannot judge" do
      let(:improvement) { { "note" => "the retry loop swallows the cause", "kind" => "bug" } }

      it "abstains (secret? false) for an input carrying no body key at all" do
        gate = described_class.new(tier: Lain::Oracle::MemorySave.heuristic)

        expect(gate.secret?(improvement)).to be(false)
      end

      it "distinguishes an ABSENT body from a present-but-contentless one" do
        gate = described_class.new(tier: Lain::Oracle::MemorySave.heuristic)

        expect(gate.secret?({ "id" => "x", "description" => "y" })).to be(false)
        expect(gate.secret?({ "id" => "x", "description" => "y", "body" => "" })).to be(true)
      end

      it "lets a real improvement_write through the real middleware, downstream and all" do
        journal = RecordingChannel.new
        guarded = Lain::Middleware::RefuseSecretWrites.new(journal:, oracle: described_class.new)
        effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "improvement_write", input: improvement)

        called = false
        env = guarded.call({ effect:, context: nil }) do |inner|
          called = true
          inner.merge(result: Lain::Tool::Result.ok("wrote"))
        end

        expect(called).to be(true)
        expect(env.fetch(:result).error?).to be(false)
        expect(journal.events).to be_empty
      end
    end

    it "passes (secret? false) when the wrapped tier judges the write worth saving" do
      gate = described_class.new(tier: Lain::Oracle::MemorySave.heuristic)

      expect(gate.secret?({ "id" => "x", "description" => "y", "body" => "500mg twice daily" })).to be(false)
    end

    it "defaults to the heuristic tier, so bare construction needs no injected tier" do
      gate = described_class.new

      expect(gate.secret?({ "id" => "x", "description" => "y", "body" => "500mg twice daily" })).to be(false)
    end
  end
end
