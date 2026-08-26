# frozen_string_literal: true

# A REAL interrupt, through the real objects: a real Agent drives a real
# ToolRunner over a real Toolset and a real Timeline inside a real reactor, and
# the run is torn by `Async::Task#cancel` -- the same call `Agent::Budget#interrupt`
# makes from Ctrl-C and from grace expiry. Nothing between the Agent and the
# Timeline is doubled, and the cancellation is not simulated by raising a
# hand-made exception: the tool is genuinely parked on an await when the cancel
# lands, which is the only way "was running" can be told from "never dispatched".
#
# The Provider is `Provider::Mock` because a live model is not the seam under
# test (that tier is `:api_integration`); every other collaborator is production.
module ToolCancellationSeam
  # Parks on an `Async::Variable` nobody resolves, announcing on another that it
  # has entered. Two variables rather than a flag and a sleep: the driver must
  # cancel while this fiber is INSIDE the await, and a poll-and-hope makes the
  # difference between the two cancellation notices a timing race.
  class Parking < Lain::Tool
    def initialize(entered:, release:)
      super()
      @entered = entered
      @release = release
    end

    def name = "park"
    def description = "Parks until released."
    def input_schema = { type: :object, properties: {} }

    def perform(_input, _context)
      @entered.resolve(true) unless @entered.resolved?
      @release.wait
      Lain::Tool::Result.ok("released")
    end
  end
end

RSpec.describe "a tool run torn by a real interrupt", :seam do
  let(:entered) { Async::Variable.new }
  let(:release) { Async::Variable.new }
  let(:parking) { ToolCancellationSeam::Parking.new(entered:, release:) }
  let(:toolset) { Lain::Toolset.new([EchoTool.new, parking]) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }
  let(:torn) do
    torn_run(agent_over(["tu_1", "echo", { "text" => "first" }],
                        ["tu_2", "park", {}],
                        ["tu_3", "echo", { "text" => "third" }]))
  end

  # Three calls in wire order: one that returns, one that parks, one the tear
  # never reaches. None of these tools is `parallel_safe?`, so the runner
  # dispatches them sequentially -- which is what makes all three states
  # (finished, running, never dispatched) reachable in ONE turn.
  def agent_over(*calls)
    Lain::Agent.new(
      provider: Lain::Provider::Mock.new(responses: [tool_response(*calls), text_response]),
      toolset:, context:
    )
  end

  # Ask, wait until the parking tool is genuinely parked, then cancel the task
  # hosting the run exactly as Budget#interrupt does.
  def torn_run(agent)
    Sync do |task|
      run = task.async { agent.ask("hi") }
      entered.wait
      run.stop
      run.wait
    end
    agent
  end

  def results_turn(agent) = agent.timeline.to_a.last

  it "keeps the finished tool's own output rather than overwriting it with a cancellation" do
    blocks = results_turn(torn).content

    expect(blocks.first).to include("tool_use_id" => "tu_1", "content" => "first", "is_error" => false)
  end

  it "answers every unanswered call, in wire order" do
    blocks = results_turn(torn).content

    expect(blocks.map { |block| block["tool_use_id"] }).to eq(%w[tu_1 tu_2 tu_3])
    expect(blocks.map { |block| block["type"] }).to eq(%w[tool_result tool_result tool_result])
  end

  it "commits the results as ONE user turn above the assistant turn that made the calls" do
    turn = results_turn(torn)

    expect(turn.role).to eq("user")
    expect(torn.timeline.to_a.map(&:role)).to eq(%w[user assistant user])
  end

  it "renders a conversation the Messages API would accept" do
    rendered = context.render(timeline: torn.timeline, toolset:).messages

    expect(Lain::Context::Conversation.new(rendered)).to be_valid
  end

  it "distinguishes a call that was running from one that was never dispatched" do
    running, undispatched = results_turn(torn).content.values_at(1, 2)

    expect(running["content"]).not_to eq(undispatched["content"])
    expect(running["content"]).to eq(Lain::Agent::ToolRunner::Answers.was_running)
    expect(undispatched["content"]).to eq(Lain::Agent::ToolRunner::Answers.never_dispatched)
    expect([running, undispatched].map { |block| block["is_error"] }).to eq([true, true])
  end

  it "claims effects may be partly applied only for the call that had started" do
    running, undispatched = results_turn(torn).content.values_at(1, 2)

    expect(running["content"]).to include("effects may be partly applied")
    expect(undispatched["content"]).to include("did not run and had no effects")
  end

  it "journals what was cancelled, naming the calls and the assistant turn they came from" do
    journal = []
    agent = Lain::Agent.new(
      provider: Lain::Provider::Mock.new(responses: [tool_response(["tu_1", "echo", { "text" => "first" }],
                                                                   ["tu_2", "park", {}],
                                                                   ["tu_3", "echo", { "text" => "third" }]),
                                                     text_response]),
      toolset:, context:, journal:
    )
    torn_run(agent)

    record = journal.grep(Lain::Telemetry::ToolCancelled).first
    expect(record.cancelled).to eq(%w[tu_2 tu_3])
    expect(record.running).to eq(["tu_2"])
    expect(record.completed).to eq(["tu_1"])
    expect(record.head).to eq(agent.timeline.to_a[1].digest)
  end

  it "gains nothing when the turn's tools all returned" do
    journal = []
    agent = Lain::Agent.new(
      provider: Lain::Provider::Mock.new(responses: [tool_response(["tu_1", "echo", { "text" => "a" }]),
                                                     text_response]),
      toolset:, context:, journal:
    )
    agent.ask("hi")

    expect(agent.timeline.to_a[2].content.map { |block| block["content"] }).to eq(["a"])
    expect(journal.grep(Lain::Telemetry::ToolCancelled)).to be_empty
  end

  # The harvest DECISION, end to end through a real Tools::AskHuman. The torn
  # turn carries the answer -- the ask_human that completed before the tear has
  # its real result in this very commit -- so this is the turn whose
  # causal_parents retire the question. Not harvesting would leave the
  # answer in the record with nothing citing it, and let a later, unrelated turn
  # claim the edge instead.
  it "cites a question answered before the tear, so it does not stay pending forever" do
    agent = nil
    ask = Lain::Tools::AskHuman.new(parent: -> { agent.timeline })
    agent = Lain::Agent.new(
      provider: Lain::Provider::Mock.new(responses: [tool_response(["tu_1", "ask_human", { "question" => "db?" }],
                                                                   ["tu_2", "park", {}]),
                                                     text_response]),
      toolset: Lain::Toolset.new([ask, parking]), context:
    )

    Sync do |task|
      run = task.async { agent.ask("hi") }
      ask.reply("postgres", ask.last_question.digest)
      entered.wait
      run.stop
      run.wait
    end

    torn_turn = results_turn(agent)
    expect(torn_turn.content.map { |block| block["content"] }).to start_with("postgres")
    expect(torn_turn.causal_parents).to eq([ask.last_question.digest])
    log = agent.timeline.to_a + [ask.last_question, ask.last_answer]
    expect(Lain::Event::Projection.new(log).pending("human").to_a).to be_empty
  end

  # THE CONTRACT: `CLI::Resume::Cancellation` projects a block for the same
  # fact when a torn session is LOADED. Two shapes for one fact is how two
  # repairs of one defect come to disagree, so the agreement is asserted
  # mechanically here rather than kept by eye.
  describe "agreement with the load-side repair" do
    let(:tear_side) do
      [Lain::Agent::ToolRunner::Answers.never_dispatched,
       Lain::Agent::ToolRunner::Answers.was_running]
    end

    # The one head both repairs answer: an assistant turn carrying a lone
    # unanswered tool_use, which is what `Event.pending_tool_use?` names.
    let(:stranded) do
      Lain::Timeline.empty(store: Lain::Store.new)
                    .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                    .commit(role: :assistant,
                            content: [{ "type" => "tool_use", "id" => "tu_2",
                                        "name" => "park", "input" => {} }]).head
    end

    it "mints the identical block shape for one stranded call" do
      at_load = Lain::CLI::Resume::Cancellation.new(stranded).blocks.first
      at_tear = results_turn(torn).content[1]

      # Key ORDER is deliberately not the contract: `Canonical` sorts keys on
      # the way into the Store, so a block read back off the Timeline is sorted
      # while the projection is read before its own commit. Which keys, and
      # every value but the sentence, are.
      expect(at_tear.keys.sort).to eq(at_load.keys.sort)
      expect(at_tear.except("content")).to eq(at_load.except("content"))
    end

    it "reports every cancelled call as an error, on both sides" do
      at_load = Lain::CLI::Resume::Cancellation.new(stranded).blocks

      expect(at_load.map { |block| block["is_error"] }).to all(be(true))
      expect(results_turn(torn).content.drop(1).map { |block| block["is_error"] }).to all(be(true))
    end

    # Load-bearing and verified rather than assumed: the load-side projection
    # carries no turn meta because one turn mixes real results with cancelled
    # ones, so the fact has to live per block -- and a meta added on either side later moves the
    # digest. This turn is the mixed one, so it is the right place to pin it.
    it "carries no turn meta, exactly as the projection does not" do
      expect(results_turn(torn).meta).to eq({})
    end

    it "answers each stranded call exactly once, so no two blocks share a tool_use_id" do
      ids = results_turn(torn).content.map { |block| block["tool_use_id"] }

      expect(ids.uniq).to eq(ids)
    end

    # The seam a review round moved: the shared half states only that there is no
    # result, and every inference about WHY sits in the half each side owns.
    # Referenced, so a drift is impossible rather than merely caught.
    it "states T3's shared half verbatim, and replaces only the half after it" do
      expect(Lain::Agent::ToolRunner::Answers.no_result)
        .to equal(Lain::CLI::Resume::Cancellation::NO_RESULT)
      expect(tear_side).to all(start_with("#{Lain::CLI::Resume::Cancellation::NO_RESULT} "))
    end

    it "substitutes EFFECTS_UNKNOWN rather than appending to it" do
      tails = tear_side.map { |notice| notice.delete_prefix("#{Lain::CLI::Resume::Cancellation::NO_RESULT} ") }

      expect(tails).to all(satisfy { |tail| !tail.include?(Lain::CLI::Resume::Cancellation::EFFECTS_UNKNOWN) })
      expect(tails.uniq.size).to eq(2)
    end

    it "hands the journal a deeply frozen record, notices included" do
      expect(tear_side).to all(be_frozen)
      expect(Lain::Telemetry::ToolCancelled.new(head: "blake3:x", cancelled: %w[tu_2]))
        .to(satisfy { |record| Ractor.shareable?(record) })
    end
  end
end
