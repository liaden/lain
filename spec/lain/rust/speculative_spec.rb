# frozen_string_literal: true

# The two capabilities M4-1.4/1.5 exist for, exercised end-to-end against the
# Rust Timeline: localizing a cache break to the last shared turn, and N-way
# speculative branching that forks in O(1) over a shared Store and selects the
# best candidate (the beam-search shape).
RSpec.describe "Lain::Ext::Timeline speculation" do
  let(:store) { Lain::Ext::Store.new }

  def text(body) = [{ "type" => "text", "text" => body }]

  def say(from, body, role: :user) = from.commit(role: role, content: text(body))

  def empty = Lain::Ext::Timeline.empty(store: store)

  describe "cache-break localization (4-1.4)" do
    it "localizes divergence to the last shared turn, so the prefix stays cache-valid" do
      base = say(say(say(empty, "sys"), "a"), "b", role: :assistant)
      left = say(base, "left")
      right = say(base, "right")

      # diverge_at is the localization primitive: the newest turn both branches
      # share. Everything up to it has identical digests, so a prompt cache built
      # over that prefix is still valid on both branches.
      expect(left.diverge_at(right)).to eq(base.head)
      shared = base.to_a.map(&:digest)
      expect(left.to_a.map(&:digest).first(shared.length)).to eq(shared)
      expect(right.to_a.map(&:digest).first(shared.length)).to eq(shared)

      # The first DIFFERING digest is each branch's own head -- the break, and
      # nothing before it, is what must be re-encoded.
      expect(left.head_digest).not_to eq(right.head_digest)
    end

    it "returns nil when two chains share no prefix at all" do
      expect(say(empty, "x").diverge_at(say(empty, "y"))).to be_nil
    end
  end

  describe "speculative branching (4-1.5)" do
    it "forks one node into N candidates over the shared store and selects the max" do
      base = say(say(empty, "sys"), "task")
      before = store.size

      candidates = %w[alpha beta gamma delta].map { |body| say(base.fork, body) }

      # O(1) fork + shared prefix stored once: only the N new heads are written.
      expect(store.size).to eq(before + candidates.length)

      # Every candidate meets the base back AT the base -- they share the whole
      # prefix and diverge only at their own head.
      expect(candidates).to all(satisfy { |candidate| candidate.meet(base) == base })

      # Beam-search shape: score each candidate in its own right, pick the best.
      score = ->(timeline) { timeline.head.content.first["text"] == "gamma" ? 100 : 1 }
      best = candidates.max_by(&score)
      expect(best.head.content.first["text"]).to eq("gamma")
    end
  end
end
