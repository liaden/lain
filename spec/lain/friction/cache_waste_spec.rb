# frozen_string_literal: true

require "bigdecimal"

# The two halves of a cache-waste meter, joined. `Bench::Rewrites` knows
# WHERE a prompt prefix broke; the Journal's `turn_usage` records know what the
# next call was BILLED for; `PriceBook` turns the difference into dollars.
#
# The card's central difficulty is segmentation. `Bench::Rewrites` documents
# (rewrites.rb:34-42) that `Request#prefix_digests` folds `model` into every
# entry, so a `/model` switch disagrees at every shared position and reads as
# one rewrite at the earliest -- "indistinguishable from a real prefix edit".
# `/model` is a normal move, so an unsegmented waste meter inflates on most real
# sessions. Every chain below that must be genuinely per-model is built through
# a REAL `Lain::Request`, so the pin breaks if that conflation ever changes.
#
# Fixtures are literal Hashes with NON-ZERO cache fields on purpose:
# `Provider::Mock` reports all-zero cache fields (`response.rb:49`), so a
# mock-backed fixture would let every assertion here pass while asserting
# nothing.
RSpec.describe Lain::Friction::CacheWaste do
  # The `request_sent` shape `Telemetry::RequestSent#to_journal` writes: the
  # model lives in `payload` because the payload IS `Request#cache_payload`.
  def request_sent(chain, model: "claude-opus-4-8", version: Lain::Request::PREFIX_CHAIN_VERSION)
    { "type" => "request_sent", "digest" => "blake3:req", "payload" => { "model" => model },
      "stream" => true, "extra" => {}, "prefix_digests" => chain, "prefix_chain_version" => version }
  end

  # The `turn_usage` shape, which is where the BILLED cache split lives.
  def turn_usage(model: "claude-opus-4-8", creation: 0, read: 0, input: 0, output: 0)
    { "type" => "turn_usage", "digest" => "blake3:turn", "model" => model, "stop_reason" => "end_turn",
      "usage" => { "input_tokens" => input, "output_tokens" => output,
                   "cache_creation_input_tokens" => creation, "cache_read_input_tokens" => read } }
  end

  # A real chain, so "the chains are per-model" is exercised rather than assumed.
  def real_chain(model:, text: "hi")
    Lain::Request.new(
      model:,
      system: [{ "type" => "text", "text" => "be terse", "cache" => true }],
      messages: [{ "role" => "user", "content" => [{ "type" => "text", "text" => text, "cache" => true }] }],
      max_tokens: 64
    ).prefix_digests
  end

  # The `capability_degraded` shape `Telemetry::CapabilityDegraded#to_journal`
  # writes, and which `Bench::Session::Loader#degraded` already reads offline.
  # Taken verbatim from the round-8 ollama session journal.
  def capability_degraded(capability: "prompt_caching")
    { "type" => "capability_degraded", "capability" => capability,
      "requirer" => "Lain::Context", "provider" => "Lain::Provider::Ollama" }
  end

  # A broken prefix reports re-billed tokens and their cost.
  describe "a prefix that broke, and the cache creation the next call was billed for" do
    subject(:waste) { described_class.from_journal(entries) }

    let(:entries) do
      [request_sent([[0, "blake3:a"]]),
       turn_usage(creation: 20_000),
       request_sent([[0, "blake3:a-EDITED"]]),
       turn_usage(creation: 12_000)]
    end

    it "attributes one re-billing, at the depth the prefix broke" do
      expect(waste.count).to eq(1)
      expect(waste.first.depth).to eq(0)
    end

    it "counts the tokens the call AFTER the break re-bought" do
      expect(waste.rebilled_tokens).to eq(12_000)
    end

    # 12_000 tokens x opus cache-creation ($6.25/MTok, the corrected table)
    # = $0.075 exactly. BigDecimal throughout: a drifting cost metric is worse
    # than none (price_book.rb's own reasoning).
    it "prices those tokens at that call's own model rate" do
      expect(waste.rebilled_cost.amount).to eq(BigDecimal("0.075"))
      expect(waste.rebilled_cost).to be_complete
    end

    # The non-inflation guard, and the reason this is not just "sum every
    # cache_creation": the FIRST call's 20_000-token write had no preceding
    # break, so it bought a cache rather than re-buying one.
    it "does not count a cache write that no break preceded" do
      expect(waste.rebilled_tokens).not_to eq(32_000)
    end
  end

  # A model switch is not counted as waste. THE card's central difficulty.
  describe "a prefix divergence that is only a model switch" do
    subject(:waste) { described_class.from_journal(entries) }

    let(:entries) do
      [request_sent(real_chain(model: "claude-opus-4-8"), model: "claude-opus-4-8"),
       turn_usage(model: "claude-opus-4-8", creation: 20_000),
       request_sent(real_chain(model: "claude-haiku-4-5"), model: "claude-haiku-4-5"),
       turn_usage(model: "claude-haiku-4-5", creation: 12_000)]
    end

    # The half that makes the rest non-vacuous: UNSEGMENTED, this exact journal
    # reads as a real prefix edit. If Bench::Rewrites ever stopped reporting it,
    # this example fails and the segmentation below stops proving anything.
    it "is one rewrite to the unsegmented projection" do
      expect(Lain::Bench::Rewrites.from_journal(entries).count).to eq(1)
    end

    it "attributes no re-billing to it" do
      expect(waste.count).to eq(0)
      expect(waste.rebilled_tokens).to eq(0)
      expect(waste.rebilled_cost.amount).to eq(BigDecimal(0))
      expect(waste.rebilled_cost).to be_complete
    end

    it "reports the switch, so the absence is explained rather than merely silent" do
      expect(waste.model_switches).to eq(1)
    end

    it "still sees both models" do
      expect(waste.models).to contain_exactly("claude-opus-4-8", "claude-haiku-4-5")
    end
  end

  # The other half: segmentation must not SUPPRESS a real edit that
  # happens to sit near a switch. Within one model's segment, a real break is
  # still a break.
  describe "a real edit inside one model's run, after a switch" do
    subject(:waste) { described_class.from_journal(entries) }

    let(:entries) do
      [request_sent([[0, "blake3:a"]], model: "claude-opus-4-8"),
       turn_usage(model: "claude-opus-4-8", creation: 20_000),
       request_sent([[0, "blake3:h"]], model: "claude-haiku-4-5"),
       turn_usage(model: "claude-haiku-4-5", creation: 5_000),
       request_sent([[0, "blake3:h-EDITED"]], model: "claude-haiku-4-5"),
       turn_usage(model: "claude-haiku-4-5", creation: 8_000)]
    end

    it "counts the in-segment edit and not the switch" do
      expect(waste.count).to eq(1)
      expect(waste.rebilled_tokens).to eq(8_000)
      expect(waste.model_switches).to eq(1)
    end

    # 8_000 x haiku cache-creation ($1.25/MTok) = $0.01. Priced at HAIKU, not
    # at the opus rate the session opened with.
    it "prices the re-billing at the segment's model, not the session's first" do
      expect(waste.rebilled_cost.amount).to eq(BigDecimal("0.01"))
    end
  end

  # A session whose cache never broke.
  describe "a session where every call read the cache" do
    subject(:waste) { described_class.from_journal(entries) }

    let(:entries) do
      [request_sent([[0, "blake3:a"]], model: "claude-sonnet-4-6"),
       turn_usage(model: "claude-sonnet-4-6", read: 100_000),
       request_sent([[0, "blake3:a"]], model: "claude-sonnet-4-6"),
       turn_usage(model: "claude-sonnet-4-6", read: 100_000)]
    end

    it "reports no waste" do
      expect(waste.count).to eq(0)
      expect(waste.rebilled_tokens).to eq(0)
    end

    # The anti-metric guard (ROADMAP.md:233): a waste figure alone rewards an
    # agent that reads nothing. What the cache BOUGHT is reported beside it.
    it "reports what the cache bought" do
      expect(waste.cached_tokens).to eq(200_000)
    end

    # 200_000 sonnet tokens at the cache-read rate ($0.30/MTok) rather than as
    # fresh input ($3/MTok): $0.60 - $0.06 = $0.54 saved.
    it "prices what the cache bought" do
      expect(waste.cached_savings.amount).to eq(BigDecimal("0.54"))
      expect(waste.cached_savings).to be_complete
    end
  end

  # The reusable object the card asks for: `cache_read_input_tokens == 0`,
  # segmented per model, is exactly ROADMAP.md:221-225's cache-aware compaction
  # scheduler sensor ("run only when the cache is already cold"). It is an
  # object so that scheduler is a card, not a re-derivation out of report prose.
  describe "the per-call cache fact" do
    subject(:waste) do
      described_class.from_journal(
        [request_sent([[0, "blake3:a"]]), turn_usage(creation: 20_000, read: 0),
         request_sent([[0, "blake3:a"]]), turn_usage(creation: 0, read: 90_000)]
      )
    end

    it "answers cold? per call, from the billed cache read alone" do
      expect(waste.calls.map(&:cold?)).to eq([true, false])
    end

    it "carries the model each reading belongs to, so a scheduler segments the same way" do
      expect(waste.calls.map(&:model)).to eq(%w[claude-opus-4-8 claude-opus-4-8])
    end

    # A `request_sent` with no following `turn_usage` is how a FAILURE reads
    # (middleware/journal_requests.rb:20). An attempt that was never billed is
    # not a priced call and must not become a free one.
    it "counts only calls the Journal actually billed" do
      unbilled = described_class.from_journal([request_sent([[0, "blake3:a"]])])

      expect(unbilled.calls).to be_empty
    end

    # The mirror limit, and the reason every figure is scoped to "priced
    # calls" rather than to the session: `Middleware::JournalRequests` is wired
    # into the MAIN agent alone, so a subagent's `turn_usage` arrives with no
    # `request_sent` beside it -- no chain, so no attributable prefix.
    it "ignores a usage record that no request preceded" do
      orphan = described_class.from_journal([turn_usage(creation: 50_000, read: 50_000)])

      expect(orphan.calls).to be_empty
      expect(orphan.cached_tokens).to eq(0)
    end
  end

  describe "a model with no price" do
    subject(:waste) do
      described_class.from_journal(
        [request_sent([[0, "blake3:a"]], model: "claude-fable-5"),
         turn_usage(model: "claude-fable-5", creation: 10_000),
         request_sent([[0, "blake3:a-EDITED"]], model: "claude-fable-5"),
         turn_usage(model: "claude-fable-5", creation: 7_000)]
      )
    end

    # PriceBook raises UnknownModel rather than guessing, and `lain friction`
    # must not die on a journal it was handed. Reported in TOKENS, never priced
    # at zero: "a silently-free model is a lie" (price_book.rb:48-50).
    it "still counts the tokens" do
      expect(waste.rebilled_tokens).to eq(7_000)
    end

    it "prices nothing rather than pricing it free, and says the figure is incomplete" do
      expect(waste.rebilled_cost.amount).to eq(BigDecimal(0))
      expect(waste.rebilled_cost).not_to be_complete
      expect(waste.unpriced_models).to eq(["claude-fable-5"])
    end
  end

  describe "a journal that records no model at all" do
    subject(:waste) do
      described_class.from_journal(
        [{ "type" => "request_sent", "prefix_digests" => [[0, "blake3:a"]], "prefix_chain_version" => 1 },
         { "type" => "turn_usage", "digest" => "d", "model" => nil, "stop_reason" => "end_turn",
           "usage" => { "cache_creation_input_tokens" => 4_000 } },
         { "type" => "request_sent", "prefix_digests" => [[0, "blake3:b"]], "prefix_chain_version" => 1 },
         { "type" => "turn_usage", "digest" => "d", "model" => nil, "stop_reason" => "end_turn",
           "usage" => { "cache_creation_input_tokens" => 3_000 } }]
      )
    end

    # Nothing to segment ON, so the un-modelled calls form one segment and read
    # exactly as Bench::Rewrites reads them today -- no worse, and no dollars
    # invented for a model nobody recorded.
    it "keeps the unsegmented reading and reports it unpriced" do
      expect(waste.rebilled_tokens).to eq(3_000)
      expect(waste.rebilled_cost.amount).to eq(BigDecimal(0))
      expect(waste.rebilled_cost).not_to be_complete
      expect(waste.unpriced_models).to eq([described_class::UNRECORDED_MODEL])
    end
  end

  # `chunk_while` chunked into MAXIMAL CONSECUTIVE runs, so an alternating
  # `/model` session put every opus call in a run of length 1 and the meter
  # became structurally incapable of reporting anything. But the prompt cache is
  # keyed per `(model, prefix)` -- an intervening haiku call does not touch the
  # opus cache, so two opus calls with a haiku between them genuinely share a
  # cache and genuinely re-bill. `rewrites.rb:41` says segment per ARM, not per
  # consecutive run.
  describe "a session that alternates models across a real edit" do
    subject(:waste) { described_class.from_journal(entries) }

    # opus prefix genuinely edited on every opus turn; haiku's never changes.
    let(:entries) do
      %w[a a-EDIT-1 a-EDIT-2].each_with_index.flat_map do |opus_digest, index|
        [request_sent([[0, "blake3:#{opus_digest}"]], model: "claude-opus-4-8"),
         turn_usage(model: "claude-opus-4-8", creation: 30_000),
         request_sent([[0, "blake3:h"]], model: "claude-haiku-4-5"),
         turn_usage(model: "claude-haiku-4-5", creation: 1_000, read: index)]
      end
    end

    it "compares the opus calls across the intervening haiku ones" do
      expect(waste.count).to eq(2)
      expect(waste.rebilled_tokens).to eq(60_000)
    end

    # 60_000 x opus cache-creation ($6.25/MTok) = $0.375.
    it "prices the whole re-billing" do
      expect(waste.rebilled_cost.amount).to eq(BigDecimal("0.375"))
      expect(waste.rebilled_cost).to be_complete
    end

    it "still counts every consecutive model change as a switch" do
      expect(waste.model_switches).to eq(5)
    end

    # The contradiction the panel found: the unsegmented analyzer reported five
    # rewrites in the SAME render where the priced one issued a clean bill.
    it "does not issue a clean bill while Bench::Rewrites reports churn" do
      expect(Lain::Bench::Rewrites.from_journal(entries).count).to be_positive
      expect(Lain::Friction::Report.new(entries).render).not_to include("cache_waste: none")
    end
  end

  # `Tools::Subagent` hands the child the SESSION's journal, and its
  # long-lived actor can land a `turn_usage` between the parent's `request_sent`
  # and the parent's own. Positional pairing then consumes the CHILD's record as
  # the parent's and discards the parent's real one.
  describe "a subagent's usage journaled between a request and its own usage" do
    subject(:waste) { described_class.from_journal(entries) }

    # The ORDER here is the fixture, not an arrangement detail. The interloper
    # must sit after a request that already has a predecessor IN ITS ARM --
    # placed before the first request's usage it does not reproduce at all, and
    # an early draft of this example scored a coincidentally-correct 12,000 and
    # proved nothing. Both orderings pass now, so nothing else in the suite can
    # catch a later tidy that moves it back to the harmless position.
    let(:entries) do
      [request_sent([[0, "blake3:a"]], model: "claude-opus-4-8"),
       turn_usage(model: "claude-opus-4-8", creation: 20_000),
       request_sent([[0, "blake3:a-EDITED"]], model: "claude-opus-4-8"),
       turn_usage(model: "claude-haiku-4-5", creation: 500_000),
       turn_usage(model: "claude-opus-4-8", creation: 12_000)]
    end

    it "refuses the interloper rather than pairing it with the parent's request" do
      expect(waste.calls.size).to eq(2)
      expect(waste.models).to eq(["claude-opus-4-8"])
    end

    it "keeps the request pending so its OWN usage still pairs" do
      expect(waste.rebilled_tokens).to eq(12_000)
      expect(waste.rebilled_cost.amount).to eq(BigDecimal("0.075"))
    end

    it "counts the refusal rather than dropping it silently" do
      expect(waste.refused_usages).to eq(1)
    end

    # Containment, not equality: the two fields legitimately differ in
    # specificity (a request may name the alias where the usage reports the
    # resolved snapshot).
    it "accepts a usage whose model merely differs in specificity" do
      paired = described_class.from_journal(
        [request_sent([[0, "blake3:a"]], model: "claude-opus-4-8"),
         turn_usage(model: "claude-opus-4-8-20260101", creation: 9_000)]
      )

      expect(paired.calls.size).to eq(1)
      expect(paired.refused_usages).to eq(0)
    end
  end

  # `rebilled_cost` summed only the priceable rebills, so a mixed journal
  # with the break on the UNPRICED side printed the exact `$0.000000` that was
  # already removed for the all-unpriced case. The object must know whether the
  # figure behind it is complete.
  describe "a figure that could only be partly priced" do
    subject(:waste) { described_class.from_journal(entries) }

    # fable breaks (unpriced); opus never does. So models != unpriced_models,
    # while every DOLLAR of the re-billing is unknown.
    let(:entries) do
      [request_sent([[0, "blake3:f"]], model: "claude-fable-5"),
       turn_usage(model: "claude-fable-5", creation: 10_000),
       request_sent([[0, "blake3:f-EDITED"]], model: "claude-fable-5"),
       turn_usage(model: "claude-fable-5", creation: 7_000),
       request_sent([[0, "blake3:o"]], model: "claude-opus-4-8"),
       turn_usage(model: "claude-opus-4-8", read: 100_000)]
    end

    it "counts the tokens but declares the cost incomplete" do
      expect(waste.rebilled_tokens).to eq(7_000)
      expect(waste.rebilled_cost.amount).to eq(BigDecimal(0))
      expect(waste.rebilled_cost).not_to be_complete
    end

    it "marks a savings figure incomplete when an unpriced model read the cache" do
      mixed = described_class.from_journal(
        [request_sent([[0, "blake3:f"]], model: "claude-fable-5"),
         turn_usage(model: "claude-fable-5", read: 1_000_000),
         request_sent([[0, "blake3:o"]], model: "claude-opus-4-8"),
         turn_usage(model: "claude-opus-4-8", read: 2_000)]
      )

      expect(mixed.cached_savings).not_to be_complete
    end

    # Zero tokens at an unknown rate is exactly zero, so absence of pricing
    # only taints a figure that had tokens behind it.
    it "keeps a figure complete when the unpriced model bought nothing" do
      quiet = described_class.from_journal(
        [request_sent([[0, "blake3:f"]], model: "claude-fable-5"),
         turn_usage(model: "claude-fable-5", read: 0),
         request_sent([[0, "blake3:o"]], model: "claude-opus-4-8"),
         turn_usage(model: "claude-opus-4-8", read: 2_000)]
      )

      expect(quiet.cached_savings).to be_complete
    end
  end

  # `payload["model"]` reached the render verbatim. A local model is
  # routinely configured BY PATH, and this report's stated constraint is
  # digests, token counts and dollars -- never a path.
  describe "a model name that is not a model name" do
    it "reduces a path-configured local model to its basename" do
      waste = described_class.from_journal(
        [request_sent([[0, "blake3:a"]], model: "/home/tara/models/qwen3-8b.gguf"),
         turn_usage(model: "/home/tara/models/qwen3-8b.gguf", creation: 5_000)]
      )

      expect(waste.models).to eq(["qwen3-8b.gguf"])
      expect(waste.models.join).not_to include("/home/tara")
    end

    it "refuses a non-String model rather than stringifying whatever it is" do
      leaky = { "note" => "sk-ant-LEAKED", "path" => "/home/someone/private" }
      waste = described_class.from_journal(
        [request_sent([[0, "blake3:a"]], model: leaky),
         { "type" => "turn_usage", "digest" => "d", "model" => leaky, "stop_reason" => "end_turn",
           "usage" => { "cache_creation_input_tokens" => 5_000 } }]
      )

      expect(waste.models).to eq([described_class::UNRECORDED_MODEL])
    end

    it "leaves an ordinary vendor or namespaced name alone" do
      %w[claude-opus-4-8 qwen3:8b llama3.1-70b].each do |name|
        waste = described_class.from_journal(
          [request_sent([[0, "blake3:a"]], model: name), turn_usage(model: name, creation: 1)]
        )

        expect(waste.models).to eq([name])
      end
    end
  end

  # The card asked for the cache fact as a REUSABLE object, and
  # ROADMAP.md:221-225's scheduler asks "is the cache cold right now" of the
  # `turn_usage` it just saw. Reaching it through `from_journal` would re-fold
  # the whole journal every turn, over `request_sent` payloads that
  # `turn_stream.rb` itself calls O(n^2) in bytes.
  describe "the cache fact, reachable from one usage record alone" do
    it "answers cold? without a request, a chain or a journal fold" do
      fact = described_class.cache_fact(turn_usage(creation: 5_000, read: 0))

      expect(fact.cold?).to be(true)
      expect(fact.model).to eq("claude-opus-4-8")
    end

    it "answers warm when the cache served the turn" do
      expect(described_class.cache_fact(turn_usage(read: 90_000))).not_to be_cold
    end

    it "sanitizes the model name on this door too" do
      fact = described_class.cache_fact(turn_usage(model: "/home/tara/models/qwen3-8b.gguf", read: 1))

      expect(fact.model).to eq("qwen3-8b.gguf")
    end
  end

  # NIT: `cache_waste.rb` argued to inherit Ledger::Index::Entry's raise on a
  # usage-less record while `price_for` twenty lines below declined instead.
  # One doctrine: DECLINE, never fabricate and never crash a report the user
  # ran over whatever journal they had.
  describe "a corrupt payment record" do
    subject(:waste) do
      described_class.from_journal(
        [request_sent([[0, "blake3:a"]]),
         { "type" => "turn_usage", "digest" => "d", "model" => "claude-opus-4-8",
           "stop_reason" => "end_turn" },
         request_sent([[0, "blake3:a-EDITED"]]),
         turn_usage(creation: 12_000)]
      )
    end

    it "does not crash the report" do
      expect { waste }.not_to raise_error
    end

    it "declines the record and counts it, rather than pricing it free" do
      expect(waste.refused_usages).to eq(1)
      expect(waste.calls.size).to eq(1)
    end
  end

  # A provider with no prompt cache reports BOTH cache fields as 0 on every
  # call (`provider/ollama/decoding.rb:91-93`), so the fixtures in this block are
  # all-zero where every other fixture in this file is deliberately not. That is
  # not an exemption from the premise at the top: all-zero IS the shape under
  # test here, and what is asserted is the capability the journal recorded --
  # a fact no cache field can supply, and the one every token figure in this
  # class had silently assumed the answer to.
  describe "a journal that records the provider had no prompt cache" do
    subject(:waste) do
      described_class.from_journal(
        [capability_degraded,
         request_sent([[0, "blake3:a"]], model: "qwen3-coder:30b"),
         turn_usage(model: "qwen3-coder:30b"),
         request_sent([[0, "blake3:a-EDITED"]], model: "qwen3-coder:30b"),
         turn_usage(model: "qwen3-coder:30b")]
      )
    end

    it "carries the degraded capability the journal recorded" do
      expect(waste.degraded.to_a).to eq(%i[prompt_caching])
    end

    it "answers that there was no prompt cache to waste" do
      expect(waste).to be_prompt_cache_degraded
    end

    it "still attributes the prefix break, which happened whether or not it was billed" do
      expect(waste.count).to eq(1)
      expect(waste.rebilled_tokens).to be_zero
    end

    it "stays deeply frozen with the capability fact aboard" do
      expect(Ractor.shareable?(waste)).to be(true)
    end
  end

  # Review fix (Linus). `capability_degraded` is written ONCE per session and
  # names a PROVIDER; every figure in this class is keyed by MODEL, because a
  # model is all `request_sent`/`turn_usage` record. The two cannot be joined,
  # so a session that degraded prompt_caching on ollama and then `/model`-switched
  # to a provider that really caches carries a session-wide "degraded" flag over
  # calls that genuinely read and re-bought a cache. Claiming cachelessness there
  # would swallow those tokens under a sentence contradicting them -- the exact
  # "two true numbers that read as a lie" defect this card exists to remove.
  describe "a degraded record over calls that did use a cache" do
    def switched(read:, creation: 0)
      [capability_degraded,
       request_sent([[0, "blake3:a"]], model: "qwen3-coder:30b"), turn_usage(model: "qwen3-coder:30b"),
       request_sent([[0, "blake3:b"]], model: "claude-opus-4-8"), turn_usage(model: "claude-opus-4-8", read:),
       request_sent([[0, "blake3:b-EDITED"]], model: "claude-opus-4-8"),
       turn_usage(model: "claude-opus-4-8", creation:, read: 100_000)]
    end

    it "still answers that the RECORD said the cache was degraded" do
      expect(described_class.from_journal(switched(read: 200_000, creation: 90_000)))
        .to be_prompt_cache_degraded
    end

    it "declines the cacheless CLAIM while a cache read contradicts it" do
      expect(described_class.from_journal(switched(read: 200_000, creation: 90_000)))
        .not_to be_no_prompt_cache
    end

    # The re-billed half of the predicate, ISOLATED: not one cache read in the
    # whole session, so `cached_tokens.zero?` is true and only the re-billing
    # stands between the record and the cacheless claim. A mutant dropping that
    # conjunct survives every other example here.
    it "declines it on a re-billed cache write alone, with no cache read anywhere" do
      waste = described_class.from_journal(
        [capability_degraded,
         request_sent([[0, "blake3:a"]], model: "claude-opus-4-8"),
         turn_usage(model: "claude-opus-4-8"),
         request_sent([[0, "blake3:a-EDITED"]], model: "claude-opus-4-8"),
         turn_usage(model: "claude-opus-4-8", creation: 40_000)]
      )

      expect(waste.cached_tokens).to be_zero
      expect(waste.rebilled_tokens).to eq(40_000)
      expect(waste).to be_prompt_cache_degraded
      expect(waste).not_to be_no_prompt_cache
    end

    it "makes the claim only when nothing measured contradicts the record" do
      quiet = described_class.from_journal(
        [capability_degraded, request_sent([[0, "blake3:a"]], model: "qwen3-coder:30b"),
         turn_usage(model: "qwen3-coder:30b")]
      )

      expect(quiet).to be_no_prompt_cache
    end
  end

  # Review fix (Jeremy). `lain friction` is a reader of whatever journal a user
  # points it at, and `Capability::DegradedSet` maps `to_sym` over every member.
  # Any non-nil value that does not answer it raised NoMethodError straight out
  # of the report -- the crash `Pairing`'s decline-never-crash doctrine exists to
  # prevent, and which the source comment already claimed was handled.
  describe "a capability_degraded record whose capability is not a name" do
    it "drops every value that cannot be a capability, rather than raising" do
      %i[nil number array object boolean].zip([nil, 7, [], { "n" => 1 }, true]).each do |label, value|
        waste = described_class.from_journal(
          [{ "type" => "capability_degraded", "capability" => value },
           request_sent([[0, "blake3:a"]]), turn_usage(read: 5)]
        )

        expect(waste.degraded.to_a).to eq([]), "#{label} was not dropped"
        expect(waste).not_to be_prompt_cache_degraded
      end
    end

    it "keeps a real capability recorded alongside a torn one" do
      waste = described_class.from_journal(
        [{ "type" => "capability_degraded", "capability" => 7 }, capability_degraded,
         request_sent([[0, "blake3:a"]]), turn_usage]
      )

      expect(waste.degraded.to_a).to eq(%i[prompt_caching])
    end
  end

  # The last AC, and the reason the fact is a RECORD rather than an inference:
  # `capability_degraded` is written only where a `:degrade` policy resolved a
  # missing capability, on the live chat path. A strict-policy run and a
  # hand-assembled journal both carry none, and neither is evidence of a cache.
  describe "a journal that records no degraded capability" do
    it "does not read that absence as a working prompt cache" do
      waste = described_class.from_journal([request_sent([[0, "blake3:a"]]), turn_usage])

      expect(waste).not_to be_prompt_cache_degraded
      expect(waste.degraded).to be_empty
    end

    it "reads some OTHER degraded capability as no answer about the cache" do
      waste = described_class.from_journal(
        [capability_degraded(capability: "thinking"), request_sent([[0, "blake3:a"]]), turn_usage]
      )

      expect(waste.degraded.to_a).to eq(%i[thinking])
      expect(waste).not_to be_prompt_cache_degraded
    end
  end

  describe "as a value" do
    # Two calls with a break between them, so `@rebills` is POPULATED and the
    # Rebill/Dollars members are actually exercised -- a one-call fixture
    # leaves the array empty and proves nothing about them.
    it "is deeply frozen, like every value derived from the Journal" do
      waste = described_class.from_journal(
        [request_sent([[0, "blake3:a"]]), turn_usage(creation: 20_000, read: 5_000),
         request_sent([[0, "blake3:a-EDITED"]]), turn_usage(creation: 12_000, read: 9_000)]
      )

      expect(waste.count).to eq(1)
      expect(Ractor.shareable?(waste)).to be(true)
    end
  end

  # Rendered through the report this joins, which is where the ACs are phrased.
  describe "rendered through Friction::Report" do
    def render(entries) = Lain::Friction::Report.new(entries).render

    it "is named among the analyzers that ran" do
      expect(Lain::Friction::Report::ANALYZERS).to include("Friction::CacheWaste")
    end

    it "states the re-billed token count and its cost" do
      rendered = render([request_sent([[0, "blake3:a"]]), turn_usage(creation: 20_000),
                         request_sent([[0, "blake3:a-EDITED"]]), turn_usage(creation: 12_000)])

      expect(rendered).to include("cache_waste")
      expect(rendered).to include("12000")
      expect(rendered).to include("0.075")
    end

    # The anti-metric half: never a waste figure on its own.
    it "reports the waste beside what the cache bought" do
      rendered = render([request_sent([[0, "blake3:a"]]), turn_usage(creation: 20_000, read: 5_000),
                         request_sent([[0, "blake3:a-EDITED"]]), turn_usage(creation: 12_000, read: 40_000)])

      expect(rendered).to include("45000")
      expect(rendered).to include("served from cache")
    end

    # The report must attribute no waste to it AND SAY WHY.
    it "says why a model switch is not waste" do
      rendered = render([request_sent(real_chain(model: "claude-opus-4-8"), model: "claude-opus-4-8"),
                         turn_usage(model: "claude-opus-4-8", creation: 20_000),
                         request_sent(real_chain(model: "claude-haiku-4-5"), model: "claude-haiku-4-5"),
                         turn_usage(model: "claude-haiku-4-5", creation: 12_000)])

      expect(rendered).to include("model switch")
      expect(rendered).to include(Lain::Friction::Report::MODEL_SWITCH_NOTE)
    end

    # Stated, not omitted.
    it "states there was no cache waste rather than omitting the section" do
      rendered = render([request_sent([[0, "blake3:a"]], model: "claude-sonnet-4-6"),
                         turn_usage(model: "claude-sonnet-4-6", read: 100_000),
                         request_sent([[0, "blake3:a"]], model: "claude-sonnet-4-6"),
                         turn_usage(model: "claude-sonnet-4-6", read: 100_000)])

      expect(rendered).to include("cache_waste: none")
      expect(rendered).to include("200000")
    end

    # The round-8 ollama session rendered `4 prefix rewrites detected`
    # and, two lines later, `saving $0.000000` -- a confident dollar figure from
    # a provider that has no cache to save with.
    it "says the provider does not cache, and quotes no saving, when the journal recorded that" do
      rendered = render([capability_degraded,
                         request_sent([[0, "blake3:a"]], model: "qwen3-coder:30b"),
                         turn_usage(model: "qwen3-coder:30b"),
                         request_sent([[0, "blake3:a-EDITED"]], model: "qwen3-coder:30b"),
                         turn_usage(model: "qwen3-coder:30b")])

      expect(rendered).to include("does not cache")
      expect(rendered).not_to include("saving $")
      expect(rendered).not_to include("$0.000000")
    end

    # The headline and the context sentence are two withholdings, and each needs
    # its own pin: "0 tokens served from cache" is a true measurement that still
    # implies a cache which happened to serve nothing, so a cacheless session
    # must not be described with it even once the vacuous dollar tail is gone.
    it "does not describe a cacheless session as a cache that served zero" do
      rendered = render([capability_degraded,
                         request_sent([[0, "blake3:a"]], model: "qwen3-coder:30b"),
                         turn_usage(model: "qwen3-coder:30b")])

      expect(rendered).to include("with no prompt cache to serve or save against")
      expect(rendered).not_to include("tokens served from cache")
    end

    # Two journals identical but for the one record, so the cacheless
    # statement is pinned to the RECORD rather than to the all-zero cache
    # fields both journals share -- an inference from those fields cannot tell a
    # cacheless provider from a session too short to have cached anything, and
    # the report may claim neither.
    it "does not read an absent capability record as either answer" do
      session = [request_sent([[0, "blake3:a"]], model: "qwen3-coder:30b"),
                 turn_usage(model: "qwen3-coder:30b"),
                 request_sent([[0, "blake3:a-EDITED"]], model: "qwen3-coder:30b"),
                 turn_usage(model: "qwen3-coder:30b")]

      unrecorded = render(session)

      expect(unrecorded).to include("cache_waste")
      expect(unrecorded).not_to include("does not cache")
      expect(unrecorded).not_to eq(render([capability_degraded] + session))
    end

    # Review fix (Linus), rendered. The cacheless sentence must not appear over a
    # line that is simultaneously billing a cache, and the real tokens and the
    # real saving must survive.
    it "reports the real cache reads and saving when a degraded session switched to a caching model" do
      rendered = render([capability_degraded,
                         request_sent([[0, "blake3:a"]], model: "qwen3-coder:30b"),
                         turn_usage(model: "qwen3-coder:30b"),
                         request_sent([[0, "blake3:b"]], model: "claude-opus-4-8"),
                         turn_usage(model: "claude-opus-4-8", read: 200_000),
                         request_sent([[0, "blake3:b-EDITED"]], model: "claude-opus-4-8"),
                         turn_usage(model: "claude-opus-4-8", creation: 90_000, read: 100_000)])

      expect(rendered).to include("300000 tokens served from cache")
      expect(rendered).to include("saving $1.350000")
      expect(rendered).not_to include("does not cache")
      expect(rendered).not_to include("no prompt cache to serve or save against")
    end

    # The same, with nothing re-billed: the "none" headline must not become the
    # cacheless one while a quarter-million cache reads sit under it.
    it "does not swallow real cache reads under the cacheless headline" do
      rendered = render([capability_degraded,
                         request_sent([[0, "blake3:a"]], model: "qwen3-coder:30b"),
                         turn_usage(model: "qwen3-coder:30b"),
                         request_sent([[0, "blake3:b"]], model: "claude-opus-4-8"),
                         turn_usage(model: "claude-opus-4-8", read: 250_000)])

      expect(rendered).to include("250000 tokens served from cache")
      expect(rendered).not_to include("does not cache")
    end

    # Review fix (Jeremy, judgement taken). The reported sentence -- `saving
    # $0.000000` -- survived on any journal carrying no capability record, which
    # is every recorded bench session and every strict-policy run. Withheld now
    # for a reason that needs no inference about the provider: zero tokens times
    # any rate is zero, so the figure reports the multiplication, not the
    # session. The token count stays; only the vacuous dollar tail goes.
    it "quotes no dollar saving when no cache tokens were served, capability record or not" do
      rendered = render([request_sent([[0, "blake3:a"]], model: "qwen3-coder:30b"),
                         turn_usage(model: "qwen3-coder:30b"),
                         request_sent([[0, "blake3:a-EDITED"]], model: "qwen3-coder:30b"),
                         turn_usage(model: "qwen3-coder:30b")])

      expect(rendered).to include("0 tokens served from cache")
      expect(rendered).not_to include("$0.000000")
      expect(rendered).not_to include("saving $")
    end

    # The Friction doctrine (ROADMAP.md:1218-1223): a section PROPOSES with
    # evidence, it never applies. The waste line carries a knob, like every
    # other signal in this report.
    it "proposes a knob rather than applying anything" do
      rendered = render([request_sent([[0, "blake3:a"]]), turn_usage(creation: 20_000),
                         request_sent([[0, "blake3:a-EDITED"]]), turn_usage(creation: 12_000)])

      expect(rendered).to include(Lain::Friction::Report::KNOBS.fetch(:cache_waste))
    end

    # A "$0.000000" beside a non-zero token count reads as "this was free" --
    # the lie PriceBook refuses to tell by raising. Withheld, never zeroed.
    it "withholds the dollar figure when no model in the journal has a price" do
      rendered = render([request_sent([[0, "blake3:a"]], model: "claude-fable-5"),
                         turn_usage(model: "claude-fable-5", creation: 10_000),
                         request_sent([[0, "blake3:a-EDITED"]], model: "claude-fable-5"),
                         turn_usage(model: "claude-fable-5", creation: 7_000)])

      expect(rendered).to include("7000 tokens re-billed")
      expect(rendered).to include("cost unpriced")
      expect(rendered).to include("claude-fable-5")
      # The re-billing specifically carries no dollar figure. This assertion is
      # about the RE-BILLING alone and stays scoped to it: the savings figure is
      # withheld here too, but for the unrelated reason that zero tokens were
      # served (review fix, Jeremy) -- two withholdings with two causes, and
      # conflating them would let either one's regression hide behind the other.
      expect(rendered).not_to match(/re-billed[^;]*costing \$/)
    end

    # The bug the all-unpriced guard missed. `models != unpriced_models`
    # here, so the old predicate printed a figure -- and `rebilled_cost` had
    # dropped every unpriced rebill, so that figure was exactly `$0.000000`.
    it "withholds the dollar figure when the BREAK is on the unpriced side of a mixed journal" do
      rendered = render([request_sent([[0, "blake3:f"]], model: "claude-fable-5"),
                         turn_usage(model: "claude-fable-5", creation: 10_000),
                         request_sent([[0, "blake3:f-EDITED"]], model: "claude-fable-5"),
                         turn_usage(model: "claude-fable-5", creation: 7_000),
                         request_sent([[0, "blake3:o"]], model: "claude-opus-4-8"),
                         turn_usage(model: "claude-opus-4-8", read: 100_000)])

      expect(rendered).to include("7000 tokens re-billed")
      expect(rendered).to include("unpriced")
      expect(rendered).not_to include("$0.000000")
    end

    # The upper-bound reasoning and the main-agent scoping are both argued
    # in the source, where nobody running `lain friction SESSION` sees them.
    it "puts the error direction and the scope in the sentence a user reads" do
      rendered = render([request_sent([[0, "blake3:a"]]), turn_usage(creation: 20_000),
                         request_sent([[0, "blake3:a-EDITED"]]), turn_usage(creation: 12_000)])

      expect(rendered).to include("at most 12000 tokens re-billed")
      expect(rendered).to include("main-agent call(s)")
    end

    # Integration check 9 greps a real run's journal for a credential
    # against exactly this. A local model is configured BY PATH.
    it "never renders a filesystem path, even as a model name" do
      rendered = render([request_sent([[0, "blake3:a"]], model: "/home/tara/models/qwen3-8b.gguf"),
                         turn_usage(model: "/home/tara/models/qwen3-8b.gguf", creation: 5_000)])

      expect(rendered).not_to include("/home/tara")
      expect(rendered).to include("qwen3-8b.gguf")
    end

    it "still prints dollars when only SOME of the journal's models are unpriced" do
      rendered = render([request_sent([[0, "blake3:a"]]), turn_usage(creation: 20_000),
                         request_sent([[0, "blake3:a-EDITED"]]), turn_usage(creation: 12_000),
                         request_sent([[0, "blake3:z"]], model: "claude-fable-5"),
                         turn_usage(model: "claude-fable-5", creation: 9_000)])

      expect(rendered).to include("$0.075000")
      expect(rendered).to include("dollar figures exclude claude-fable-5")
    end

    it "leaves a journal with no priced call alone, rather than reporting a zero" do
      expect(render([request_sent([[0, "blake3:a"]])])).not_to include("cache_waste")
    end

    it "renders byte-identical output across repeated calls" do
      entries = [request_sent([[0, "blake3:a"]]), turn_usage(creation: 20_000),
                 request_sent([[0, "blake3:a-EDITED"]]), turn_usage(creation: 12_000)]

      expect(render(entries)).to eq(render(entries))
    end

    # The privacy constraint, checked at integration against a real run's
    # journal: digests, token counts and dollars only. The model name is read
    # OUT of `payload`, which carries the whole message history -- so the one
    # field taken from it must be the only thing that can reach the render.
    it "emits no message content and no path, though it reads a payload full of both" do
      loud = request_sent([[0, "blake3:a"]])
      loud["payload"] = loud["payload"].merge(
        "messages" => [{ "role" => "user",
                         "content" => [{ "type" => "text", "text" => "the token is sk-ant-SECRETVALUE" }] }],
        "system" => "/home/someone/private/notes.md"
      )

      rendered = render([loud, turn_usage(creation: 20_000),
                         request_sent([[0, "blake3:a-EDITED"]]), turn_usage(creation: 12_000)])

      expect(rendered).not_to include("SECRETVALUE")
      expect(rendered).not_to include("/home/someone")
    end
  end
end
