# frozen_string_literal: true

require "json"
require "stringio"

# `/rewind` moves the live session backward with zero model turns --
# Agent#rewind in place, the move journaled as an additive `rewound` record
# ({from:, to:}) so the file's fold can follow the checkout and the session
# stays loadable. A bad target (unknown digest, out-of-range count) refuses
# loudly, names the valid range, and changes nothing: not the machine, not
# the file.
RSpec.describe Lain::CLI::Command::Rewind do
  subject(:command) { described_class.new }

  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:chronicle) { Lain::CLI::Chronicle.new(journal:).start(context:, toolset:) }
  let(:provider) do
    Lain::Provider::Mock.new(responses: [text_response("one"), text_response("two"), text_response("post-rewind")])
  end

  # Two settled asks: user/assistant/user/assistant, four committed turns,
  # caught up the way the Repl's deliver keeps the record current.
  let(:agent) do
    Lain::Agent.new(provider:, toolset:, context:).tap do |built|
      built.ask("first")
      built.ask("second")
      chronicle.catch_up(built.timeline)
    end
  end
  let(:env) { build_command_env(agent:, chronicle:) }

  def records = journal_io.string.each_line.map { |line| JSON.parse(line) }
  def of_type(type) = records.select { |record| record["type"] == type }
  def hex(digest) = digest.delete_prefix("blake3:")

  def state = [agent.timeline.head_digest, journal_io.string.dup]

  def refuses(argument, matching)
    before = state
    expect { command.call(argument, env) }.to raise_error(Lain::Error, matching)
    expect(state).to eq(before)
  end

  describe "/rewind N (AC: rewind N turns without loss)" do
    it "moves the machine back N turns in place and journals rewound {from:, to:}" do
      from = agent.timeline.head_digest
      target = agent.timeline.rewind(2).head_digest

      text = command.call("2", env)

      expect(agent.timeline.head_digest).to eq(target)
      expect(of_type("rewound"))
        .to contain_exactly(a_hash_including("type" => "rewound", "from" => from, "to" => target))
      expect(text).to be_a(String).and include("rewound")
    end

    it "defaults to one turn on a bare /rewind" do
      target = agent.timeline.rewind(1).head_digest

      command.call("", env)

      expect(agent.timeline.head_digest).to eq(target)
    end

    it "renders the NEXT request from the rewound head -- the discarded turns never reach the provider" do
      command.call("2", env)
      agent.ask("retry")

      rendered = JSON.generate(provider.requests.last.messages)
      expect(rendered).to include("first", "retry")
      expect(rendered).not_to include("second")
    end

    it "reopens the machine so the session continues from the rewound head" do
      command.call("2", env)

      expect(JSON.generate(agent.ask("retry").content)).to include("post-rewind")
    end
  end

  describe "/rewind <digest> (resolution rules against this session's own chain)" do
    it "resolves a hex prefix to the recorded turn and rewinds to it" do
      target = agent.timeline.rewind(3).head_digest

      command.call(hex(target)[0, 12], env)

      expect(agent.timeline.head_digest).to eq(target)
      expect(of_type("rewound").first).to include("to" => target)
    end

    it "accepts the full blake3:-schemed digest too" do
      target = agent.timeline.rewind(1).head_digest

      command.call(target, env)

      expect(agent.timeline.head_digest).to eq(target)
    end
  end

  describe "a bad target fails loudly and changes nothing (AC)" do
    it "refuses a count exceeding history, naming the valid range" do
      refuses("9", /1\.\.4/)
    end

    it "refuses zero, naming the valid range" do
      refuses("0", /1\.\.4/)
    end

    it "refuses a negative count with the range message, not a digest mismatch" do
      refuses("-1", /out of range.*1\.\.4/m)
    end

    it "refuses a digest recorded nowhere on this session's chain, naming it and the range" do
      refuses("blake3:#{"f" * 64}", /no turn matching/)
    end

    it "refuses the head itself -- there is nothing to rewind to" do
      refuses(hex(agent.timeline.head_digest), /already the head/)
    end

    it "refuses on an empty session -- no committed turn to rewind past" do
      fresh = Lain::Agent.new(provider:, toolset:, context:)
      chronicle
      empty_env = build_command_env(agent: fresh, chronicle:)

      expect { command.call("1", empty_env) }.to raise_error(Lain::Error, /no committed turns/)
    end
  end

  # Panel fix 1 (Jeremy): a loaded session refuses a head that is an assistant
  # tool_use turn still awaiting its results and cannot be repaired
  # ({Lain::CLI::Resume::MidTool});
  # /rewind must not CREATE that head -- the next ask would render a dangling
  # tool_use (a real-API 400). It moves a LIVE head and projects nothing, so
  # unlike a resume there is no load to answer the stranded call: the torn turn
  # would simply be the head. (The older second reason -- "the journaled file
  # would then refuse to resume" -- stopped being true once resume learned to
  # repair that file rather than refuse it. The first reason is sufficient.)
  describe "a mid-tool target is refused (parity with the session-loading doors)" do
    let(:provider) do
      Lain::Provider::Mock.new(responses: [tool_response(["tu_1", "echo", { "text" => "ping" }]),
                                           text_response("done")])
    end
    let(:agent) do
      Lain::Agent.new(provider:, toolset:, context:).tap do |built|
        built.ask("use the tool")
        chronicle.catch_up(built.timeline)
      end
    end

    # timeline: user / assistant(tool_use) / user(tool_result) / assistant(text)
    it "refuses a count landing on the dangling tool_use, naming the nearest valid targets" do
      refuses("2", /tool_use.*nearest valid targets: 1, 3/m)
    end

    it "refuses a digest target that IS the tool_use turn, through the same guard" do
      refuses(hex(agent.timeline.rewind(2).head_digest)[0, 12], /tool_use turn/)
    end

    # The human typed a digest, so the refusal says that digest back: a count
    # they never typed reads as a different command. And the results do exist
    # -- the rewind would only move past them.
    it "restates a digest target as typed, and says the results would be rewound past" do
      prefix = hex(agent.timeline.rewind(2).head_digest)[0, 4]

      expect { command.call(prefix, env) }.to raise_error(described_class::Refusal) do |error|
        expect(error.message).to start_with("/rewind #{prefix} ")
        expect(error.message).not_to include("/rewind 2")
        expect(error.message).to include("rewound past")
      end
    end

    it "still allows rewinding PAST the whole tool exchange" do
      command.call("3", env)

      expect(agent.timeline.head.role).to eq("user")
      expect(agent.timeline.length).to eq(1)
    end
  end

  # A parked tool call belongs to a run that is still going to settle onto the
  # Timeline it captured and hand that Timeline back, so a head moved now is
  # re-committed over the moment the call is answered. The same in-flight
  # predicate /undo refuses on.
  describe "while a tool call is parked" do
    let(:provider) do
      Lain::Provider::Mock.new(responses: [text_response("one"),
                                           tool_response(["tu_ask", "ask_human", { "question" => "which db?" }]),
                                           text_response("settled")])
    end
    let(:asker) { Lain::Tools::AskHuman.new(parent: -> { parked_agent.timeline }) }
    let(:parked_agent) do
      Lain::Agent.new(provider:, toolset: Lain::Toolset.new([EchoTool.new, asker]), context:).tap do |built|
        built.ask("first")
        chronicle.catch_up(built.timeline)
      end
    end
    let(:parked_env) { build_command_env(agent: parked_agent, chronicle:) }

    def while_parked
      [parked_agent, parked_env, asker, journal_io]
      Sync do |task|
        run = task.async { parked_agent.ask("second") }
        yield
        asker.reply("postgres", asker.last_question.digest)
        run.wait
      end
    end

    it "refuses, naming the parked call, and moves nothing" do
      while_parked do
        head = parked_agent.timeline.head_digest
        journaled = journal_io.string.dup

        expect { command.call("1", parked_env) }.to raise_error(described_class::Refusal) do |error|
          expect(error.message).to include("ask_human", "tu_ask").and match(/nothing moved/i)
          expect(error.message).to start_with("/rewind 1 ")
        end
        expect(parked_agent.timeline.head_digest).to eq(head)
        expect(journal_io.string).to eq(journaled)
      end
    end

    it "restates a digest target as typed" do
      while_parked do
        prefix = hex(parked_agent.timeline.head_digest)[0, 4]

        expect { command.call(prefix, parked_env) }
          .to raise_error(described_class::Refusal, %r{\A/rewind #{prefix} })
      end
    end

    it "commits no rewound turn again once the question is answered" do
      while_parked do
        expect { command.call("1", parked_env) }.to raise_error(described_class::Refusal)
      end

      turns = parked_agent.timeline.to_a
      expect(turns.map(&:role)).to eq(%w[user assistant user assistant user assistant])
      expect(turns.map(&:digest).uniq.size).to eq(turns.size)
      expect(turns.last.content.first["text"]).to eq("settled")
    end
  end

  # The record lands before the machine moves, so a run taking the dispatch lock
  # between the two would leave the file rewound and the machine not. Forced
  # at exactly that instant: a racing thread tries to take and hold the lock
  # while the `rewound` record is being written.
  describe "a run arriving between the record and the move" do
    let(:racing) do
      Class.new(SimpleDelegator) do
        attr_reader :raced

        def initialize(chronicle, lock)
          super(chronicle)
          @lock = lock
          @raced = []
          @release = Queue.new
        end

        def rewound(**)
          super
          taken = Queue.new
          @holder = Thread.new do
            got = @lock.try_enter
            taken.push(got)
            @release.pop && @lock.exit if got
          end
          @raced << taken.pop
        end

        def finish
          @release.push(:go)
          @holder&.join
        end
      end.new(chronicle, agent.dispatch_lock)
    end

    it "cannot take the lock, so the record and the machine agree" do
      target = agent.timeline.rewind(2).head_digest
      racing_env = build_command_env(agent:, chronicle: racing)

      begin
        command.call("2", racing_env)
      ensure
        racing.finish
      end

      expect(racing.raced).to eq([false])
      expect(agent.timeline.head_digest).to eq(target)
      expect(of_type("rewound").last).to include("to" => target)
    end

    it "keeps today's refusal when a run holds the lock first" do
      held = Queue.new
      release = Queue.new
      holder = Thread.new { agent.dispatch_lock.synchronize { held.push(:holding) && release.pop } }
      held.pop

      refuses("1", %r{\A/rewind 1 refused: a run is still in flight})
    ensure
      release&.push(:go)
      holder&.join
    end
  end

  # Panel fix 3 (Linus): journal FIRST. Timeline#rewind on a validated count
  # cannot fail, so nothing can raise between the record landing and the
  # machine moving -- a chronicle failure must never leave the machine at A
  # with the record still anchored at H (every later catch_up would raise
  # Diverged, far from the actual bug).
  describe "journal-first ordering" do
    it "a chronicle failure during /rewind leaves the machine unmoved" do
      pre = agent.timeline.head_digest
      broken = instance_double(Lain::CLI::Chronicle)
      allow(broken).to receive(:catch_up)
      allow(broken).to receive(:rewound).and_raise(IOError, "journal fd closed")
      broken_env = build_command_env(agent:, chronicle: broken)

      expect { command.call("2", broken_env) }.to raise_error(IOError)
      expect(agent.timeline.head_digest).to eq(pre)
    end
  end

  # Panel: `#moved` must journal the head THIS call is rewinding FROM, not a
  # second, later read off the agent -- `Env#checkpoint` re-reads
  # `agent.timeline` live on every call, which is one statement-reorder away
  # from catching up on the already-shortened post-rewind chain instead.
  # Pinned with a double whose `#timeline` answers DIFFERENTLY on a second
  # call, so a captured `from` and a fresh re-read are provably distinct
  # objects rather than accidentally equal because nothing mutated between
  # them yet.
  describe "catch_up receives the captured pre-rewind timeline, never a second live read" do
    it "journals the timeline this rewind moved FROM -- not whatever a later agent.timeline read answers" do
      pre = agent.timeline
      post = pre.rewind(1)
      stub_agent = instance_double(Lain::Agent, rewind: nil, dispatching?: false, dispatch_lock: Monitor.new)
      allow(stub_agent).to receive(:timeline).and_return(pre, post)
      stub_chronicle = instance_double(Lain::CLI::Chronicle, catch_up: nil, rewound: nil)
      stub_env = build_command_env(agent: stub_agent, chronicle: stub_chronicle)

      command.call("1", stub_env)

      expect(stub_chronicle).to have_received(:catch_up).with(pre)
    end
  end

  describe "a second /rewind after the first (panel: Schneeman)" do
    it "journals a fold-consistent second record: its from is the first record's to" do
      command.call("1", env)
      command.call("1", env)

      rewounds = of_type("rewound")
      expect(rewounds.size).to eq(2)
      expect(rewounds.last["from"]).to eq(rewounds.first["to"])
      loaded = Lain::Bench::Session::Loader.new(records).recording
      expect(loaded.timeline.head_digest).to eq(agent.timeline.head_digest)
    end
  end

  describe "the rewound record keeps the session loadable end to end" do
    it "Loader rebuilds the post-retry head, the pre-rewind head still reachable in the Store" do
      pre_rewind_head = agent.timeline.head_digest
      command.call("2", env)
      agent.ask("retry")
      chronicle.catch_up(agent.timeline)

      loaded = Lain::Bench::Session::Loader.new(records).recording

      expect(loaded.timeline.head_digest).to eq(agent.timeline.head_digest)
      expect(loaded.timeline.store.key?(pre_rewind_head)).to be(true)
    end
  end

  it "returns rendered text and never prints" do
    text = nil
    expect { text = command.call("1", env) }.not_to output.to_stdout

    expect(text).to be_a(String)
  end
end
