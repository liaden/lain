# frozen_string_literal: true

RSpec.describe Lain::Context::PurgeFailedInputs do
  def tool_use(id:, name:, input:)
    { "type" => "tool_use", "id" => id, "name" => name, "input" => input }
  end

  def tool_result(id:, content:, is_error: false)
    { "type" => "tool_result", "tool_use_id" => id, "content" => content, "is_error" => is_error }
  end

  def assistant(*blocks) = { "role" => "assistant", "content" => blocks }
  def user(*blocks) = { "role" => "user", "content" => blocks }

  # old-failed: outside the turns:2 window -> input purged, error text kept.
  # old-ok: outside the window but never failed -> untouched.
  # recent-failed: inside the window -> untouched, even though it failed.
  let(:messages) do
    [
      assistant(tool_use(id: "old-failed", name: "search", input: { "q" => "old", "payload" => "x" * 500 })),
      user(tool_result(id: "old-failed", content: "error: rate limited", is_error: true)),
      assistant(tool_use(id: "old-ok", name: "search", input: { "q" => "fine" })),
      user(tool_result(id: "old-ok", content: "ok")),
      assistant(tool_use(id: "recent-failed", name: "search", input: { "q" => "recent" })),
      user(tool_result(id: "recent-failed", content: "error: still broken", is_error: true))
    ]
  end

  describe "AC2: purge drops old failed inputs but keeps the error" do
    let(:purged) { described_class.new(turns: 2).call(messages) }

    it "drops the failed call's input once it ages out of the turn window" do
      expect(purged[0]["content"].first["input"]).to eq({})
    end

    it "keeps the error text of the purged call" do
      expect(purged[1]).to eq(messages[1])
      expect(purged[1]["content"].first["content"]).to eq("error: rate limited")
    end

    it "never touches a call that did not fail, regardless of age" do
      expect(purged[2]).to eq(messages[2])
    end

    it "never purges a failed call still inside the turn window" do
      expect(purged[4]).to eq(messages[4])
      expect(purged[4]["content"].first["input"]).to eq({ "q" => "recent" })
    end

    it "leaves the recent error's tool_result untouched" do
      expect(purged[5]).to eq(messages[5])
    end
  end

  it "is a no-op when the whole list fits inside the turn window" do
    expect(described_class.new(turns: messages.size).call(messages)).to eq(messages)
  end

  it "rejects a negative turns: -- silently clamping would purge everything, including the recent window" do
    expect { described_class.new(turns: -1) }.to raise_error(ArgumentError, /turns/)
  end

  it "does not mutate the input message list -- a pure projection" do
    before = Lain::Canonical.dump(messages)
    described_class.new(turns: 2).call(messages)
    expect(Lain::Canonical.dump(messages)).to eq(before)
  end

  it "is pure: identical input yields identical output" do
    combinator = described_class.new(turns: 2)
    expect(combinator.call(messages)).to eq(combinator.call(messages))
  end

  it "declares no required capabilities -- purging is purely client-side" do
    expect(described_class.new(turns: 2).requires).to eq([])
  end

  it "composes with other combinators via >>" do
    composed = described_class.new(turns: 2) >> Lain::Context::Identity
    expect(composed.call(messages)).to eq(described_class.new(turns: 2).call(messages))
  end

  # An analysis of the whole list, then a map over the AGED SLICE against it.
  # The second phase is per-message, which is what buys every output a known
  # preimage -- but the slice is positional, so unlike
  # {Lain::Context::DedupeToolCalls} this is not elementwise and says so.
  describe "the two-phase factoring" do
    it "answers the identifiers it would act on, without transforming anything" do
      before = Lain::Canonical.dump(messages)
      expect(described_class.new(turns: 2).failed_tool_use_ids(messages)).to eq(%w[old-failed recent-failed])
      expect(Lain::Canonical.dump(messages)).to eq(before)
    end

    it "reads the whole list, since a failure is recorded on the answering tool_result" do
      aged_only = messages.first(2)
      expect(described_class.new(turns: 2).failed_tool_use_ids(aged_only)).to eq(["old-failed"])
    end

    it "traces every message it rewrites to exactly one input message" do
      combinator = described_class.new(turns: 2)
      analysis = combinator.failed_tool_use_ids(messages)
      images = messages.first(4).map { |message| combinator.send(:without_failed_input, message, analysis) }

      expect(images.size).to eq(4)
      expect(images + messages.last(2)).to eq(combinator.call(messages))
      expect(images.first["content"].first["input"]).to eq({})
    end
  end

  # The negative is a first-class entry, not an absence: Algebra::Elementwise
  # is deliberately NOT included, and the refutation is filed directly. Both
  # examples below are the law failing -- an elementwise map is a function of
  # (message, analysis), and these show #call is not one.
  describe "the refutation of elementwise" do
    it "refutes elementwise on #call, naming the positional window" do
      refutation = Lain::Algebra.registry.refutations
                                .find { |entry| entry.subject == described_class }

      expect([refutation.operation, refutation.structure]).to eq(%i[call elementwise])
      expect(refutation.reason).to match(/positional/)
    end

    it "never also declares elementwise, and does not include the module" do
      expect(Lain::Algebra.registry.declares?(subject: described_class, operation: :call,
                                              structure: :elementwise)).to be(false)
      expect(described_class.new(turns: 2)).not_to be_a(Lain::Algebra::Elementwise)
    end

    # A function answers one image per argument. Here two `==` messages take
    # different images inside a SINGLE call, against a single analysis, because
    # the boundary falls between them -- so no (message, analysis) function
    # reproduces #call, whatever the analysis.
    it "gives two equal messages different images when the window falls between them" do
      failed = assistant(tool_use(id: "a", name: "search", input: { "q" => "big" }))
      transcript = [failed, user(tool_result(id: "a", content: "boom", is_error: true)), failed]

      purged = described_class.new(turns: 1).call(transcript)

      expect(purged.first["content"].first["input"]).to eq({})
      expect(purged.last["content"].first["input"]).to eq({ "q" => "big" })
      expect(transcript.first).to eq(transcript.last)
    end

    # The other law an elementwise map obeys: it is a homomorphism over `++`,
    # so where the list is split cannot matter. Splitting a failed tool_use
    # away from its error moves the window, and the two halves disagree with
    # the whole -- with distinct ids, so this is not the duplicate-id case.
    it "is not a homomorphism over concatenation: where the list is split changes the answer" do
      combinator = described_class.new(turns: 1)
      head = [assistant(tool_use(id: "a", name: "search", input: { "q" => "big" }))]
      tail = [user(tool_result(id: "a", content: "boom", is_error: true)),
              assistant({ "type" => "text", "text" => "moving on" })]

      expect(combinator.call(head + tail)).not_to eq(combinator.call(head) + combinator.call(tail))
      expect(combinator.call(head + tail).first["content"].first["input"]).to eq({})
      expect(combinator.call(head).first["content"].first["input"]).to eq({ "q" => "big" })
    end
  end

  # The panel's duplicate-id probes, pinned. Grader::ToolCallIndex documents a
  # repeated tool_use id as a wire anomaly to TOLERATE, so this class must be
  # robust to one -- an id-keyed rewrite of #call redacts protected content
  # here, silently, and that is the reason the positional slice stays.
  describe "a transcript with a repeated tool_use id" do
    let(:protect) { Lain::Context::ProtectedPatterns.new(["KEEPME"]) }

    it "never redacts a protected message because an unprotected one shares its id" do
      transcript = [
        assistant(tool_use(id: "dup", name: "search", input: { "q" => "PLAIN" })),
        assistant({ "type" => "text", "text" => "KEEPME" },
                  tool_use(id: "dup", name: "search", input: { "q" => "SECRET" })),
        user(tool_result(id: "dup", content: "boom", is_error: true)),
        assistant(tool_use(id: "tail", name: "search", input: { "q" => "t" }))
      ]

      purged = described_class.new(turns: 1, protected_patterns: protect).call(transcript)

      expect(purged[1]["content"].last["input"]).to eq({ "q" => "SECRET" })
      expect(purged[0]["content"].first["input"]).to eq({})
    end

    it "never redacts a call inside the window because an aged one shares its id" do
      transcript = [
        assistant(tool_use(id: "dup", name: "search", input: { "q" => "AGED" })),
        user(tool_result(id: "dup", content: "boom", is_error: true)),
        assistant(tool_use(id: "dup", name: "search", input: { "q" => "RECENT" }))
      ]

      purged = described_class.new(turns: 2).call(transcript)

      expect(purged.last["content"].first["input"]).to eq({ "q" => "RECENT" })
      expect(purged.first["content"].first["input"]).to eq({})
    end

    it "never redacts a user message's tool_use, whatever id it carries" do
      transcript = [
        assistant(tool_use(id: "dup", name: "search", input: { "q" => "A" })),
        user(tool_use(id: "dup", name: "search", input: { "q" => "U" })),
        user(tool_result(id: "dup", content: "boom", is_error: true)),
        assistant(tool_use(id: "tail", name: "search", input: { "q" => "t" }))
      ]

      purged = described_class.new(turns: 1).call(transcript)

      expect(purged[1]["content"].first["input"]).to eq({ "q" => "U" })
    end
  end

  describe "the monoid law (property-tested)" do
    let(:pool) { { purge: described_class.new(turns: 2), identity: Lain::Context::Identity } }

    def compose(sequence)
      sequence.map { |symbol| pool.fetch(symbol) }.reduce(Lain::Context::Identity, :>>)
    end

    def observe(combinator)
      combinator.call(messages)
    end

    include_examples "a monoid",
                     operation: ->(a, b) { a >> b },
                     identity: Lain::Context::Identity,
                     generator: -> { compose(Array.new(rand(0..3)) { %i[purge identity].sample }) },
                     equal: ->(a, b) { observe(a) == observe(b) }
  end
end
