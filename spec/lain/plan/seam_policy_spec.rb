# frozen_string_literal: true

# PC-3: two execution SHAPES behind one continuation contract. A seam policy
# answers `at_seam(state:, closure:) -> Continuation`, where a Continuation names
# the mainline to continue on (as a head digest, so the value stays
# Ractor-shareable) AND the render pipeline for subsequent turns. ForkPerStep
# acts on the timeline half (the chunk's fork dies; only the closure digest
# commits to an append-only mainline; pipeline unchanged); LinearRewrite acts on
# the pipeline half (the timeline stays linear; subsequent turns render through a
# Compact whose summarizer is EVERY closed chunk's deterministic rendering).
# Plan::Runner drives a Plan::Document under either shape, owning per-turn Context
# construction -- so switching shape changes zero plan content, and the difference
# shows up only in the prefix-digest churn: linear rewrites the cached prefix at a
# seam, fork never does.

# Shareable module-scope fixtures: a Proc's `self` must be shareable for
# Ractor.make_shareable, so the pipeline providers live here (self == the module),
# never inside an example (self == the example group, unshareable).
module SeamPolicyFixtures
  # The PRODUCTION-DEFAULT cache-marking pipeline. The churn AC (linear = 1
  # rewrite, fork = 0, at the second seam) holds under it -- no dense-marking
  # probe is needed to expose the difference, so the card fixture uses exactly
  # what a real render would.
  DEFAULT = Ractor.make_shareable(->(_workspace) { Lain::Context::CacheBreakpoints.new })

  # The agent for one step, over Provider::Mock end-to-end: it renders through
  # the Runner-built Context (so the Mock records a request reflecting the live
  # pipeline), then commits a user+assistant pair -- two turns, enough for
  # LinearRewrite's Compact to have a head to summarize.
  class FixtureStep
    attr_reader :provider

    def initialize
      response = Lain::Response.new(stop_reason: :end_turn, content: [], usage: Lain::Usage.new)
      @provider = Lain::Provider::Mock.new(responses: [response])
      @toolset = Lain::Toolset.new([])
    end

    def call(step:, timeline:, context:, workspace:)
      @provider.complete(context.render(timeline:, toolset: @toolset, workspace:))
      advanced = timeline
                 .commit(role: "user", content: [{ "type" => "text", "text" => "please do #{step.id}" }])
                 .commit(role: "assistant", content: [{ "type" => "text", "text" => "done #{step.id} in detail" }])
      grade = Lain::Grader::Grade.new(score: 1.0, why: "did #{step.id}")
      Lain::Plan::Runner::Outcome.new(timeline: advanced, grade:)
    end
  end
end

RSpec.describe "Lain::Plan seam policies" do
  # Three steps, each its own chunk (a seam after every step but the last), so a
  # seam is a step boundary and "the second seam" is unambiguous.
  def document
    Lain::Plan::Document.parse_markdown(<<~PLAN)
      ## Plan

      - [ ] `s1` (S) first step
      ---
      - [ ] `s2` (S) second step
      ---
      - [ ] `s3` (S) third step
    PLAN
  end

  def run_under(policy, store, pipeline: SeamPolicyFixtures::DEFAULT)
    Lain::Plan::Runner.new(document:, policy:, agent_step: SeamPolicyFixtures::FixtureStep.new,
                           model: "m", max_tokens: 16)
                      .run(timeline: Lain::Timeline.empty(store:), pipeline:)
  end

  def fork_policy(store)
    Lain::Plan::ForkPerStep.new(mainline: Lain::Timeline.empty(store:))
  end

  # The mainline as a prefix-digest chain: render each continuation (its timeline
  # through its pipeline) into a request, then hand Bench::Rewrites the chain it
  # projects rewrites over.
  def prefix_chain(continuations, store)
    continuations.map do |continuation|
      request = Lain::Context.new(model: "m", max_tokens: 16, pipeline: continuation.pipeline)
                             .render(timeline: continuation.timeline(store), toolset: Lain::Toolset.new([]),
                                     workspace: Lain::Workspace.empty)
      [Lain::Request::PREFIX_CHAIN_VERSION, request.prefix_digests]
    end
  end

  def rewrites(chain)
    Lain::Bench::Rewrites.new(chains: chain).to_a
  end

  describe "the continuation contract" do
    it "is a frozen, Ractor-shareable value: a head digest plus a shareable pipeline" do
      continuation = Lain::Plan::Continuation.new(head_digest: "blake3:abc", pipeline: SeamPolicyFixtures::DEFAULT)
      empty_head = Lain::Plan::Continuation.new(head_digest: nil, pipeline: SeamPolicyFixtures::DEFAULT)

      expect(continuation).to be_frozen
      expect(Ractor.shareable?(continuation)).to be(true)
      expect(Ractor.shareable?(empty_head)).to be(true)
    end

    it "reconstitutes its mainline Timeline over a shared Store in O(1)" do
      store = Lain::Store.new
      timeline = Lain::Timeline.empty(store:).commit(role: "user", content: [{ "type" => "text", "text" => "hi" }])
      continuation = Lain::Plan::Continuation.new(head_digest: timeline.head_digest, pipeline: SeamPolicyFixtures::DEFAULT)
      empty_head = Lain::Plan::Continuation.new(head_digest: nil, pipeline: SeamPolicyFixtures::DEFAULT)

      expect(continuation.timeline(store).head_digest).to eq(timeline.head_digest)
      expect(empty_head.timeline(store)).to be_empty
    end
  end

  describe "Scenario: fork-per-step never rewrites the mainline" do
    it "keeps every mainline chain append-only and each fork inherits the mainline prefix" do
      store = Lain::Store.new
      report = run_under(fork_policy(store), store)

      expect(rewrites(prefix_chain(report.continuations, store))).to be_empty

      report.forks.each_with_index do |fork, index|
        mainline_before = report.continuations[index].timeline(store)
        expect(mainline_before.ancestor_of?(fork)).to be(true)
      end
    end
  end

  describe "Scenario: the same plan runs under both shapes unchanged" do
    it "produces closure records for every step with equal ids and grades, plan bytes untouched" do
      plan = document
      bytes_before = plan.digest

      fork_store = Lain::Store.new
      linear_store = Lain::Store.new
      fork = run_under(fork_policy(fork_store), fork_store)
      linear = run_under(Lain::Plan::LinearRewrite.new, linear_store)

      expect(fork.closures.map(&:step_id)).to eq(%w[s1 s2 s3])
      expect(fork.closures.map(&:step_id)).to eq(linear.closures.map(&:step_id))
      expect(fork.closures.map(&:passed)).to eq(linear.closures.map(&:passed))
      expect(fork.closures.map(&:score)).to eq(linear.closures.map(&:score))
      expect(document.digest).to eq(bytes_before)
    end
  end

  describe "Scenario: linear's rewrite is visible where fork's is absent" do
    it "shows exactly one prefix rewrite at the second seam under LinearRewrite and none under ForkPerStep" do
      fork_store = Lain::Store.new
      linear_store = Lain::Store.new
      fork = run_under(fork_policy(fork_store), fork_store)
      linear = run_under(Lain::Plan::LinearRewrite.new, linear_store)

      # continuations: [seed, after-seam-1, after-seam-2, ...]; the second seam is
      # the transition between the two continuations adopted after seams 1 and 2.
      fork_pair = prefix_chain(fork.continuations, fork_store).slice(1, 2)
      linear_pair = prefix_chain(linear.continuations, linear_store).slice(1, 2)

      expect(rewrites(linear_pair).size).to eq(1)
      expect(rewrites(fork_pair)).to be_empty
    end
  end

  describe "Scenario: reopening supersedes by reference" do
    it "names the superseded closure's digest and leaves the old record unchanged in the Store" do
      store = Lain::Store.new
      policy = fork_policy(store)
      timeline = Lain::Timeline.empty(store:).commit(role: "user", content: [{ "type" => "text", "text" => "work" }])
      step = Lain::Plan::Step.new(id: "s1", title: "a step", size: "S")

      first = Lain::Plan::Closure.build(step: step.with_status("done"), timeline:, chunk_range: (0...1),
                                        grade: Lain::Grader::Grade.new(score: 1.0, why: "closed"), snapshot: nil)
      first.record(store:, plan_digest: document.digest)
      policy.at_seam(state: Lain::Plan::Continuation.new(head_digest: timeline.head_digest, pipeline: SeamPolicyFixtures::DEFAULT),
                     closure: first)

      reopened_grade = Lain::Grader::Grade.new(score: 0.0, pass: false, why: "reopened")
      reopened = Lain::Plan::Closure.build(step: step.with_status("failed"), timeline:, chunk_range: (0...1),
                                           grade: reopened_grade, snapshot: nil)
      reopened.record(store:, plan_digest: document.digest)
      reopen_state = Lain::Plan::Continuation.new(head_digest: policy.mainline.head_digest, pipeline: SeamPolicyFixtures::DEFAULT)
      policy.at_seam(state: reopen_state, closure: reopened)

      expect(policy.supersessions.size).to eq(1)
      supersession = policy.supersessions.first
      expect(supersession.superseded).to eq(first.digest)
      expect(supersession.superseding).to eq(reopened.digest)
      expect(store.fetch(first.digest)).to eq(first)
      expect(first.digest).not_to eq(reopened.digest)
    end
  end

  describe "Scenario: LinearRewrite accumulates every closed chunk's summary" do
    # A four-chunk plan, so three earlier chunks have closed by the final render.
    def four_chunk_document
      Lain::Plan::Document.parse_markdown(<<~PLAN)
        ## Plan

        - [ ] `s1` (S) first step
        ---
        - [ ] `s2` (S) second step
        ---
        - [ ] `s3` (S) third step
        ---
        - [ ] `s4` (S) fourth step
      PLAN
    end

    it "renders all four closures into one summary while the closed chunks' turns are elided" do
      store = Lain::Store.new
      report = Lain::Plan::Runner.new(document: four_chunk_document, policy: Lain::Plan::LinearRewrite.new,
                                      agent_step: SeamPolicyFixtures::FixtureStep.new, model: "m", max_tokens: 16)
                                 .run(timeline: Lain::Timeline.empty(store:), pipeline: SeamPolicyFixtures::DEFAULT)

      final = report.continuations.last
      request = Lain::Context.new(model: "m", max_tokens: 16, pipeline: final.pipeline)
                             .render(timeline: final.timeline(store), toolset: Lain::Toolset.new([]),
                                     workspace: Lain::Workspace.empty)
      texts = request.messages.flat_map { |m| Array(m["content"]).grep(Hash).filter_map { |b| b["text"] } }
      summaries = texts.select { |text| text.start_with?("[closure ") }

      # Exactly ONE summary block (Compact never stacks), naming every closed chunk.
      expect(summaries.size).to eq(1)
      expect(summaries.first).to include("closure s1", "closure s2", "closure s3", "closure s4")
      # The earlier chunks' verbatim turns are elided (summarized away), not resent.
      expect(texts).not_to include("done s1 in detail")
      expect(texts).not_to include("done s2 in detail")
    end
  end

  describe "Scenario: a mainline-bearing policy seeded from a different root fails loud" do
    it "raises MainlineMismatch when the policy mainline root differs from run's root" do
      store = Lain::Store.new
      seeded = Lain::Timeline.empty(store:).commit(role: "user", content: [{ "type" => "text", "text" => "pre" }])
      policy = Lain::Plan::ForkPerStep.new(mainline: seeded)
      runner = Lain::Plan::Runner.new(document:, policy:, agent_step: SeamPolicyFixtures::FixtureStep.new,
                                      model: "m", max_tokens: 16)

      expect { runner.run(timeline: Lain::Timeline.empty(store:), pipeline: SeamPolicyFixtures::DEFAULT) }
        .to raise_error(Lain::Plan::Runner::MainlineMismatch, /does not match run root/)
    end

    it "runs cleanly when the policy mainline root matches run's root" do
      store = Lain::Store.new
      expect { run_under(fork_policy(store), store) }.not_to raise_error
    end
  end
end
