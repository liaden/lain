# frozen_string_literal: true

require "json"
require "stringio"

# T15: `/rewind` moves the live session backward with zero model turns --
# Agent#rewind in place, the move journaled as an additive `rewound` record
# ({from:, to:}) so the file's fold can follow the checkout and the session
# stays loadable. A bad target (unknown digest, out-of-range count) refuses
# loudly, names the valid range, and changes nothing: not the machine, not
# the file.
RSpec.describe Lain::CLI::Command::Rewind do
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
  let(:env) { instance_double(Lain::CLI::Command::Env, agent:, chronicle:) }

  subject(:command) { described_class.new }

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

  describe "/rewind <digest> (T3's resolution rules against this session's own chain)" do
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
      empty_env = instance_double(Lain::CLI::Command::Env, agent: fresh, chronicle:)

      expect { command.call("1", empty_env) }.to raise_error(Lain::Error, /no committed turns/)
    end
  end

  # Panel fix 1 (Jeremy): {CLI::Resume#refuse_mid_tool!} refuses to resume a
  # head that is an assistant tool_use turn still awaiting its results;
  # /rewind must not CREATE that head -- the next ask would render a dangling
  # tool_use (a real-API 400), and the journaled file would then refuse to
  # resume through the very guard the command skipped.
  describe "a mid-tool target is refused (parity with Resume#refuse_mid_tool!)" do
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
      refuses(hex(agent.timeline.rewind(2).head_digest)[0, 12], /awaiting its tool results/)
    end

    it "still allows rewinding PAST the whole tool exchange" do
      command.call("3", env)

      expect(agent.timeline.head.role).to eq("user")
      expect(agent.timeline.length).to eq(1)
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
      broken_env = instance_double(Lain::CLI::Command::Env, agent:, chronicle: broken)

      expect { command.call("2", broken_env) }.to raise_error(IOError)
      expect(agent.timeline.head_digest).to eq(pre)
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
