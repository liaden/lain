# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

# T2: a spawned child's turns reach the session record.
#
# A child runs its own chain, and things OUTSIDE that chain cite it -- the
# `"final"` edge {Lain::Tools::Subagent::Lineage#message} writes, and the head an
# `ask_human` question is asked from. The scribe's own walk cannot reach any of
# it (a Timeline walk sees ONE chain), so every session that spawned anything
# recorded messages naming turns no record carried, and rebuilding it raised
# {Lain::Store::MissingObject}.
#
# Driven through the REAL spawn path -- a parent Agent whose toolset holds the
# subagent tool, over {Lain::Provider::Mock} -- because the whole shape of this
# defect is that the seam LOOKS wired: the scribe was observing, the events were
# arriving, and the turns they cited simply were not in the file.
RSpec.describe Lain::SessionRecord::Scribe do
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
  let(:child_context) { Lain::Context.new(model: "child-model", max_tokens: 256) }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:workspace) { Lain::Workspace.empty }
  let(:store) { Lain::Store.new }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:scribe) { described_class.new(journal:, context:, toolset:, workspace:) }

  def text(body) = [{ "type" => "text", "text" => body }]
  def records = journal_io.string.each_line.map { |line| JSON.parse(line) }
  def of_type(type) = records.select { |record| record["type"] == type }
  def digests_of(type) = of_type(type).map { |record| record["digest"] }

  # The parent's own loop, wired the way {Lain::CLI::Chronicle} wires a chat:
  # the scribe observes the event funnel and tees {Lain::Middleware::JournalTurns}
  # after every iteration. `tools` is late-bound through the same thunk the exe
  # uses, so the subagent names the parent's LIVE head.
  def chat(tools:, responses:)
    agent = nil
    toolset = Lain::Toolset.new(tools.call(-> { agent.timeline }))
    agent = Lain::Agent.new(
      provider: Lain::Provider::Mock.new(responses:), context:, toolset:,
      timeline: Lain::Timeline.empty(store:),
      turn_middleware: Lain::Middleware::Stack.new(
        [Lain::Middleware::JournalTurns.new(scribe:, timeline: -> { agent.timeline })]
      )
    )
  end

  def subagent(parent, child_responses, prefix:)
    Lain::Tools::Subagent.new(
      seam: Lain::Tools::Subagent::Seam.new(
        provider: Lain::Provider::Mock.new(responses: child_responses),
        context_factory: -> { child_context }, parent:, observer: ->(event) { scribe.call(event) }
      ),
      toolset: Lain::Toolset.new([EchoTool.new]),
      policy: Lain::Tool::SpawnPolicy.new(prefix:, posture: :schema, only: []),
      max_depth: 2
    )
  end

  # A spawn, driven to settle, recorded and closed -- the file a reader would
  # find on disk.
  def spawned_session(prefix: :fresh, child_responses: [text_response("child done")],
                      parent_responses: [tool_response(["tu_1", "subagent", { "prompt" => "go" }]),
                                         text_response("parent done")])
    agent = chat(tools: ->(parent) { [subagent(parent, child_responses, prefix:)] },
                 responses: parent_responses)
    agent.ask("please spawn")
    scribe.catch_up(agent.timeline)
    scribe.close(reason: :exit)
    agent
  end

  describe "a spawned subagent's turns reach the journal" do
    before { spawned_session }

    it "writes a record for every turn the child committed" do
      # The child's chain: its seeded user turn and its assistant reply.
      expect(of_type(Lain::SessionRecord::CHILD_TURN_TYPE).map { |record| record.dig("payload", "role") })
        .to eq(%w[user assistant])
    end

    it "names a digest the journal carries in every message record's causal_parents" do
      carried = digests_of("turn") + digests_of("message") + digests_of(Lain::SessionRecord::CHILD_TURN_TYPE)

      expect(of_type("message").flat_map { |record| record["causal_parents"] }.uniq - carried).to be_empty
    end

    # The whole point: the rebuild is what a fork does first, and it is where
    # the dangle surfaced -- as a bare Store::MissingObject, which is not the
    # {Lain::Bench::Session::Corrupt} the resume path knows how to refuse.
    it "rebuilds without raising" do
      expect { Lain::Bench::Session.load(journal_io.string.each_line) }.not_to raise_error
    end

    it "puts the child's turns in the rebuilt Store, so the cited edges resolve" do
      recording = Lain::Bench::Session.load(journal_io.string.each_line)

      expect(digests_of(Lain::SessionRecord::CHILD_TURN_TYPE))
        .to all(satisfy { |digest| recording.timeline.store.key?(digest) })
    end
  end

  describe "the main render chain is unchanged" do
    let(:agent) do
      chat(tools: ->(_parent) { [EchoTool.new] },
           responses: [tool_response(["tu_1", "echo", { "text" => "hi" }]), text_response("done")])
    end

    before do
      agent.ask("hello")
      scribe.catch_up(agent.timeline)
      scribe.close(reason: :exit)
    end

    it "holds exactly the render-chain turns, in ancestor order" do
      expect(digests_of("turn")).to eq(agent.timeline.ancestor_digests.reverse)
    end

    it "writes no child_turn record at all" do
      expect(of_type(Lain::SessionRecord::CHILD_TURN_TYPE)).to be_empty
    end
  end

  # The fold ChainFold performs, and the one this record must not disturb: a
  # session that DID spawn still re-commits to exactly its own render chain,
  # so a child turn can never be mistaken for one of it.
  describe "ChainFold's walk, over a session that spawned" do
    it "sees only the render-chain turns" do
      agent = spawned_session
      fold = Lain::Bench::Session::ChainFold.new(records:, base: Lain::Timeline.empty(store: Lain::Store.new))

      expect(fold.timeline.ancestor_digests.reverse).to eq(agent.timeline.ancestor_digests.reverse)
    end

    it "admits no child turn to its member set" do
      spawned_session
      fold = Lain::Bench::Session::ChainFold.new(records:, base: Lain::Timeline.empty(store: Lain::Store.new))
      fold.timeline

      expect(digests_of(Lain::SessionRecord::CHILD_TURN_TYPE)).to all(satisfy { |digest| !fold.member?(digest) })
    end
  end

  # The discrimination itself, at the one door off-chain events come through.
  describe "#call" do
    let(:parent) { Lain::Timeline.empty(store:).commit(role: :user, content: text("hi")) }

    it "promotes a :message as a message record" do
      writer = Lain::Event::ChainWriter.new(observer: ->(event) { scribe.call(event) })
      writer.put(parent, kind: :message, from: "human", to: "lain", causal_parents: [], body: { "text" => "hi" })

      expect(of_type("message").size).to eq(1)
    end

    it "promotes a :turn as a child_turn record carrying its render edge" do
      scribe.call(parent.ancestors.first)

      expect(of_type(Lain::SessionRecord::CHILD_TURN_TYPE).first)
        .to include("digest" => parent.head_digest, "kind" => "turn", "render_parent" => nil)
    end

    # PROBE 6, promoted. "A :turn on this funnel is a spawned chain's" is an
    # inference from WIRING, and anything holding the observer duck can break
    # it. The written chain is what answers instead of the wiring.
    it "writes no second record for a turn it already wrote as a render-chain turn" do
      agent = chat(tools: ->(_parent) { [EchoTool.new] }, responses: [text_response("done")])
      agent.ask("hello")
      scribe.catch_up(agent.timeline)

      agent.timeline.ancestors.to_a.reverse_each { |turn| scribe.call(turn) }

      expect(of_type(Lain::SessionRecord::CHILD_TURN_TYPE)).to be_empty
      expect(digests_of("turn")).to eq(agent.timeline.ancestor_digests.reverse)
    end

    # And why that check may not be a RAISE. Content addressing makes a fresh
    # child's root turn literally the parent's root turn when the spawn prompt
    # equals the human's opening message -- ONE event on two chains, verified
    # here rather than argued. The spawn happens mid-iteration, before the
    # parent's own turn has been caught up, so this session genuinely records
    # the same digest under both types and must still load: refusing would have
    # crashed an ordinary chat over a coincidence the format absorbs.
    it "still loads a spawn whose child root IS a turn the parent also writes" do
      agent = chat(tools: ->(parent) { [subagent(parent, [text_response("child done")], prefix: :fresh)] },
                   responses: [tool_response(["tu_1", "subagent", { "prompt" => "please spawn" }]),
                               text_response("parent done")])
      agent.ask("please spawn")
      scribe.catch_up(agent.timeline)
      scribe.close(reason: :exit)
      shared = digests_of(Lain::SessionRecord::CHILD_TURN_TYPE) & digests_of("turn")
      recording = nil

      expect(shared).not_to be_empty
      expect { recording = Lain::Bench::Session.load(journal_io.string.each_line) }.not_to raise_error
      expect(recording.timeline.ancestor_digests).to eq(agent.timeline.ancestor_digests)
    end
  end

  # BLOCKER 2. `message_journal:` is the --nvim tee, and {StatusFeed}'s observe
  # is duck-typed on `#kind`: a `:turn` reaching it retires a pending inbox
  # question. `status_feed.rb` records that path as a known, escalated gap and
  # says explicitly it is not one to route around unilaterally -- so a child's
  # turns must stay where every other turn record is, on the journal.
  #
  # A real {StatusFeed} sits behind the tee here, not a stand-in: the fix is
  # that the record never ARRIVES, and only the live surface itself can say so.
  # Note the trap -- a JournalTee sink is a `#<<` duck, and `Method#<<` is Proc
  # COMPOSITION, so handing it `array.method(:push)` swallows every record in
  # silence. Sinks are an Array and a StatusFeed.
  describe "routing, with a tee injected" do
    let(:sink) { [] }
    let(:status) { Lain::StatusFeed.new(path: File.join(Dir.mktmpdir("scribe-tee"), "state.json")) }
    let(:tee) { Lain::CLI::JournalTee.new(journal, sink, status) }
    let(:scribe) { described_class.new(journal:, context:, toolset:, workspace:, message_journal: tee) }
    let(:parent) { Lain::Timeline.empty(store:).commit(role: :user, content: text("hi")) }

    it "keeps a child turn off the tee while the file still gets it once" do
      child = Lain::Timeline.empty(store:).commit(role: :user, content: text("child ask"))

      scribe.call(child.ancestors.first)

      expect(of_type(Lain::SessionRecord::CHILD_TURN_TYPE).size).to eq(1)
      expect(sink).to be_empty
    end

    it "still routes a :message through the tee, delivered to the file once" do
      writer = Lain::Event::ChainWriter.new(observer: ->(event) { scribe.call(event) })
      question = writer.put(parent, kind: :message, from: "lain", to: "human",
                                    causal_parents: [], body: { "question" => "which db?" })

      expect(of_type("message").size).to eq(1)
      expect(sink.map(&:digest)).to eq([question.digest])
    end

    # The whole run, not one hand-fed event: a real spawn must put its child's
    # transcript in the FILE and nothing turn-shaped on the live surface, while
    # the telemetry that surface exists for still arrives.
    it "puts no turn record on the tee across a whole spawned session" do
      spawned_session

      expect(of_type(Lain::SessionRecord::CHILD_TURN_TYPE)).not_to be_empty
      expect(sink.map(&:kind)).to eq(%i[spawn message])
    end

    it "moves a real StatusFeed's inbox not at all, while the spawn still registers" do
      spawned_session

      expect(status.state.fetch("inbox_count")).to eq(0)
      expect(status.state.fetch("fleet").size).to eq(1)
    end
  end

  # Paths the card never named, kept as guards because they are where an
  # ordering or double-recording mistake would surface first.
  describe "shapes beyond the card's own" do
    # An `:inherit` child's turns have a render edge into the PARENT's chain,
    # so this is the one crossing from the flat replay into the ChainFold's.
    it "reloads an :inherit spawn, with the child's turns landing in the store" do
      agent = spawned_session(prefix: :inherit)
      recording = nil

      expect { recording = Lain::Bench::Session.load(journal_io.string.each_line) }.not_to raise_error
      expect(digests_of(Lain::SessionRecord::CHILD_TURN_TYPE)).not_to be_empty
      expect(recording.timeline.ancestor_digests).to eq(agent.timeline.ancestor_digests)
      expect(recording.timeline.ancestor_digests & digests_of(Lain::SessionRecord::CHILD_TURN_TYPE)).to be_empty
    end

    it "records each child's turns once across two spawns in one session" do
      spawned_session(parent_responses: [tool_response(["tu_1", "subagent", { "prompt" => "one" }]),
                                         tool_response(["tu_2", "subagent", { "prompt" => "two" }]),
                                         text_response("parent done")])
      digests = digests_of(Lain::SessionRecord::CHILD_TURN_TYPE)

      expect { Lain::Bench::Session.load(journal_io.string.each_line) }.not_to raise_error
      expect(digests.uniq).to eq(digests)
    end

    # The fan-out this record has to survive without growing linearly in
    # siblings: identical prompts AND identical replies -- a temperature-0
    # sampling arm -- make every sibling's transcript the SAME events, so a feed
    # that did not remember what it had promoted would write the whole
    # transcript once per child. Two spawns, one transcript, and the parent's
    # own chain unmoved.
    it "records one transcript for a fan-out of siblings that ran identically" do
      same = { "prompt" => "same" }
      agent = spawned_session(child_responses: [text_response("same answer"), text_response("same answer")],
                              parent_responses: [tool_response(["tu_1", "subagent", same]),
                                                 tool_response(["tu_2", "subagent", same]),
                                                 text_response("parent done")])
      digests = digests_of(Lain::SessionRecord::CHILD_TURN_TYPE)
      recording = nil

      expect(digests.uniq).to eq(digests)
      expect { recording = Lain::Bench::Session.load(journal_io.string.each_line) }.not_to raise_error
      expect(recording.timeline.ancestor_digests).to eq(agent.timeline.ancestor_digests)
    end

    # Escalation trigger 3, as a standing guard rather than an argument.
    it "prices no child turn and keeps every one off the message log" do
      spawned_session
      recording = Lain::Bench::Session.load(journal_io.string.each_line)
      children = digests_of(Lain::SessionRecord::CHILD_TURN_TYPE)

      expect(children.flat_map { |digest| recording.ledger_index.entries_for(digest) }).to be_empty
      expect(digests_of("turn_usage") & children).to be_empty
      expect(recording.messages.map(&:kind).uniq).not_to include(:turn)
    end
  end
end
