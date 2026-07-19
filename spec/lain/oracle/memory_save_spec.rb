# frozen_string_literal: true

# T4 (OR-3), second oracle arm: "worth remembering?" -- plugged into
# {Lain::Middleware::RefuseSecretWrites}'s existing `oracle:` seam via {Gate}.
# The live gate is SYNCHRONOUS (a memory_write cannot be un-written once
# indexed), so only the heuristic tier may ever back it in production; this
# spec pins that baseline and the Gate adapter that exposes it through
# `#secret?`. The end-to-end wiring through RefuseSecretWrites itself is
# pinned in refuse_secret_writes_spec.rb.
RSpec.describe Lain::Oracle::MemorySave do
  describe ".heuristic (the baseline arm)" do
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

    it "flags an opaque, unbroken token as not worth saving" do
      oracle = described_class.heuristic
      blob = ("a".."z").cycle.first(40).join

      answer = Sync { oracle.ask(id: "x", description: "y", body: blob).await }

      expect(answer.worth_saving).to be(false)
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
