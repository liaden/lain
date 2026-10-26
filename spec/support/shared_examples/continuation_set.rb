# frozen_string_literal: true

# Compaction never narrows what may legally follow: for a source timeline T and
# a continuation s, if the Messages API accepts T ++ s then it accepts
# derive(T) ++ s. The point version (derive(T) is itself valid) is refused at
# derivation time; this is the closed version, over what may come NEXT.
#
# Not a member of Algebra::STRUCTURES, whose closed list demands a refutation
# battery per member; this is a plain shared group, as the law's author
# anticipated.
#
# Include with `it_behaves_like`; the host supplies `strategy`. A host whose
# strategy never collapses (Identity) passes `collapses: false` and is held to
# derived == source instead. Every other host must collapse at least one draw,
# so a strategy that quietly declines everything cannot pass by doing nothing.
#
# Sources never end in a dangling tool_use. No production path derives from one:
# the Agent commits a tool_use and its results (the torn path included) before
# any render, an idle prepare runs only while quiescent, and the early handoff
# refuses a tool-block tail.
module ContinuationSet
  module_function

  # Fixed, and named in every failure message, so a counterexample replays.
  SEED = 63
  KEEP_LASTS = [2, 3, 4].freeze
  # Lower bounds: a tool round or a doubled user message can overshoot by one.
  MIN_SIZES = [1, 2, 3, 4, 5, 6, 8, 10, 12, 14, 16].freeze

  def text(body) = { "type" => "text", "text" => body }

  def tool_use(id) = { "type" => "tool_use", "id" => "toolu_#{id}", "name" => "read", "input" => {} }

  def tool_result(id) = { "type" => "tool_result", "tool_use_id" => "toolu_#{id}", "content" => "ok" }

  def message(role, *blocks) = { "role" => role, "content" => blocks }

  # A random walk over the conversations the Messages API accepts. Every tool_use
  # is answered by the next message, so every source is itself valid and may end
  # on either role.
  def messages(random, min_size)
    walk = [message("user", text("u0"))]
    walk += step(random, walk.size, walk.last) while walk.size < min_size
    walk
  end

  def step(random, index, last)
    return [message("user", text("u#{index}"))] if last["role"] == "assistant"

    draw = random.rand
    case draw
    when 0...0.3, 0.9..1 then [message("assistant", text("a#{index}"))]
    when 0.3...0.5 then round(index, [tool_use("#{index}a")])
    when 0.5...0.65 then round(index, [tool_use("#{index}a"), tool_use("#{index}b")])
    when 0.65...0.8 then round(index, [text("thinking #{index}"), tool_use("#{index}a")])
    else [message("user", text("u#{index}"))]
    end
  end

  def round(_index, blocks)
    answers = blocks.select { |block| block["type"] == "tool_use" }
                    .map { |call| tool_result(call["id"].delete_prefix("toolu_")) }
    [message("assistant", *blocks), message("user", *answers)]
  end

  def timelines(seed: SEED, sizes: MIN_SIZES)
    random = Random.new(seed)
    sizes.each_with_index.map { |size, index| commit(settled(messages(random, size), index)) }
  end

  # Half the sources end on assistant text, which refuses an assistant
  # continuation: without them the source filter would accept every pair.
  def settled(walk, index)
    index.odd? && walk.last["role"] == "user" ? walk + [message("assistant", text("done"))] : walk
  end

  def commit(messages)
    messages.inject(Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store)) do |timeline, message|
      timeline.commit(role: message["role"], content: message["content"])
    end
  end

  def continuations
    [[message("user", text("next"))],
     [message("assistant", text("next"))],
     [message("assistant", tool_use("c")), message("user", tool_result("c"))]]
  end

  def valid?(messages) = Lain::Context::Conversation.new(messages).valid?

  def projected(timeline) = Lain::EventLog::Messages.project(timeline.to_a)

  # What the law is read over: each (timeline, keep_last, continuation) the
  # source accepts, with whether the derived chain differs and any narrowing.
  def survey(strategy, timelines, continuations)
    draws = timelines.product(KEEP_LASTS, continuations)
    total = draws.size
    kept = draws.select { |timeline, _keep_last, continuation| valid?(projected(timeline) + continuation) }
    results = kept.map { |timeline, keep_last, continuation| derived(strategy, timeline, keep_last, continuation) }
    { total:, applicable: kept.size, changed: results.count { |result| result[:changed] },
      counterexamples: results.reject { |result| result[:ok] } }
  end

  # A derivation its own point check refuses is a counterexample too, reported
  # with the draw instead of as a bare exception.
  def derived(strategy, timeline, keep_last, continuation)
    source = projected(timeline)
    derived = projected(Lain::Compaction::Derivation.new(strategy:, keep_last:).derive(timeline))
    { ok: valid?(derived + continuation), changed: derived != source, keep_last:, source:, continuation:, derived: }
  rescue Lain::Compaction::Derivation::Invalid => e
    { ok: false, changed: true, keep_last:, source: projected(timeline), continuation:, refused: e.message }
  end
end

RSpec.shared_examples "a continuation-preserving strategy" do |collapses: true|
  let(:survey) { ContinuationSet.survey(strategy, ContinuationSet.timelines, ContinuationSet.continuations) }

  it "accepts every continuation the source accepted (seed #{ContinuationSet::SEED})", aggregate_failures: false do
    expect(survey[:counterexamples]).to be_empty
  end

  it "rejects some pairs and keeps others, so the source filter is exercised (seed #{ContinuationSet::SEED})" do
    expect(survey[:applicable]).to be_between(1, survey[:total] - 1)
  end

  it "derives a chain that differs from its source exactly when it collapses (seed #{ContinuationSet::SEED})" do
    expect(survey[:changed].positive?).to be(collapses)
  end
end
