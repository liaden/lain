# frozen_string_literal: true

require "json"
require "tmpdir"

# An :inherit child spawned after its parent handed off renders the parent's
# held cuts as they stood at spawn, over the objects a chat really wires: a
# real parent {Lain::Agent} with its real {Lain::Compaction::Source}, a real
# {Lain::Session} journaling into a real session file through a real
# {Lain::SessionRecord::Scribe}, and the real {Lain::Tools::Subagent} spawning
# over the shared `Lain::Ext::Store`. The child's own Source is a real one of the
# parent's arm. The file is read back by the real loader.
#
# The chat provider is recorded: it refuses a render still holding the
# history, as ollama does once it is asked not to truncate, so a child that
# rendered the raw inherited chain is refused and one that rendered the
# handoff document is answered.
module InheritChildCompactionSeam
  MARKER = "HISTORY-MARKER"

  REFUSES_AT = 5

  # What a spawn adds to its parent's file: the lineage, which is the child's.
  LINEAGE = %w[message child_turn].freeze

  ANSWER = { "goal" => "finish the parser", "progress" => "the lexer lands and its specs pass",
             "files_and_decisions" => "lexer.rb; hand-rolled, no regexes",
             "open_todos" => "the parser and its error messages",
             "next_step" => "write parser.rb over the lexer's token stream" }.freeze

  class Recorded
    class Refusal < Lain::Error
      include Lain::WindowExceeded
    end

    attr_reader :requests

    # @param script [Array<Lain::Response>] answers to the asks that are not
    #   refused and not the handoff question, in order; "settled" once spent
    def initialize(script: [])
      @requests = []
      @script = script.dup
    end

    def complete(request)
      @requests << request
      text = Lain::Canonical.dump(request.messages)
      return summary if text.include?("no longer fits its context window")
      raise refusal if text.include?(MARKER) && request.messages.size >= REFUSES_AT

      @script.shift || settled
    end

    def supports?(_capability) = false

    def cache_profile = Lain::CacheProfile::NO_CACHING

    private

    def settled
      Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }], stop_reason: :end_turn,
                         usage: Lain::Usage.new(input_tokens: 40, output_tokens: 2))
    end

    def refusal
      Refusal.new("request (63000 tokens) exceeds the available context size",
                  prompt_tokens: 63_000, window_tokens: 32_768, source: "ollama")
    end

    def summary
      Lain::Response.new(content: [{ "type" => "text", "text" => JSON.generate(ANSWER) }], stop_reason: :end_turn,
                         usage: Lain::Usage.new(input_tokens: 30, output_tokens: 20))
    end
  end

  # A child tool that runs the block it was built with, so a child can make its
  # parent do something between two of its own renders.
  class Poke < Lain::Tool
    def initialize(answer: "poked", &on_call)
      super()
      @answer = answer
      @on_call = on_call
    end

    def name = "poke"
    def description = "Pokes the parent."
    def input_schema = { type: :object, properties: {} }

    def perform(_input, _invocation)
      @on_call&.call
      Lain::Tool::Result.ok(@answer)
    end
  end

  # One chat: its session file, its Source, its Agent and the spawner it holds.
  class Chat
    attr_reader :agent, :session, :source, :path, :provider, :child_provider

    # `child_compacts` gives the child a Source that compacts at once, under
    # the parent's arm, so it commits a cut of its own.
    def initialize(dir:, context:, toolset:, window:, child_script: [], child_tools: [], child_compacts: false,
                   arm: nil)
      @path = File.join(dir, "session-#{object_id}.ndjson")
      @journal = Lain::Journal.new(io: File.open(@path, "ab"), owns_io: true)
      @context = context
      @window = window
      @provider = InheritChildCompactionSeam::Recorded.new
      @child_provider = InheritChildCompactionSeam::Recorded.new(script: child_script)
      @child_tools = child_tools
      @child_compacts = child_compacts
      @arm = arm
      @scribe = Lain::SessionRecord::Scribe.new(journal: @journal, context:, toolset:)
      @session = Lain::Session.new(journal: @journal)
      @source = handing_off(@journal)
      @agent = agent_over(toolset)
    end

    def fill = 2.times { |index| ask("#{InheritChildCompactionSeam::MARKER} question #{index}: #{"slept. " * 20}") }

    def ask(text)
      @agent.ask(text).tap { @scribe.catch_up(@agent.timeline) }
    end

    # `run` is the entry `/meta` reaches through {Lain::Skill::RoleSpawn}.
    def spawn(prompt, view: true)
      subagent(view:).run(prompt)
    end

    def close
      @scribe.catch_up(@agent.timeline)
      @scribe.close(reason: :exit)
      @journal.close
    end

    def lines = File.readlines(@path)

    def records = lines.map { |line| JSON.parse(line) }

    def cuts = records.select { |record| record["type"] == "compaction_cut" }

    private

    def subagent(view:)
      Lain::Tools::Subagent.new(
        seam: Lain::Tools::Subagent::Seam.new(
          tool_middleware: ToolRegistry::UNGUARDED, provider: @child_provider, context_factory: -> { @context },
          parent: -> { @agent.timeline }, journal: @journal, observer: ->(event) { @scribe.call(event) }
        ),
        toolset: Lain::Toolset.new(@child_tools),
        policy: Lain::Tool::SpawnPolicy.new(prefix: :inherit, posture: :schema, only: @child_tools.map(&:name)),
        compaction: view ? parent_view : Lain::Tools::Subagent::ParentView::None
      )
    end

    # The child's Source is the parent's arm, journaling nowhere: its
    # decisions are the child's, and the parent's file is not where they go.
    def parent_view
      knobs = @child_compacts ? { threshold: 1, keep_last: 2 } : {}
      Lain::Tools::Subagent::ParentView.new(session: @session, arm: collapse(Lain::Channel::Null.instance).name,
                                            source: -> { handing_off(Lain::Channel::Null.instance, **knobs) })
    end

    def handing_off(journal, threshold: 1_000_000, keep_last: 20)
      Lain::Compaction::Source.new(
        need: Lain::Compaction::Need.new(byte_threshold: threshold),
        cold: Lain::Compaction::Cold.new(cache_profile: Lain::CacheProfile::NO_CACHING, journal:),
        hard_cap: threshold, keep_last:, journal:, context_window: @window, strategy: collapse(journal),
        fallback: Lain::Compaction::Source::Fallback.new(tier: -> { handoff_tier })
      )
    end

    # `elide-tools` asks no model, so a child under it compacts with nothing
    # but its own chain.
    def collapse(journal)
      return Lain::Compaction::Source::Collapse.new if @arm.nil?

      Lain::Compaction::Source::Collapse.new(policy: Lain::CLI::CompactionStrategy.resolve(@arm, journal:), name: @arm)
    end

    def handoff_tier
      definition = Lain::Oracle::Handoff.definition
      inner = Lain::Oracle::Model.new(definition:, provider: @provider, model: "qwen3:4b", max_tokens: 512)
      Lain::Oracle::Recorded::Journaling.new(inner:, definition:, journal: @journal)
    end

    def agent_over(toolset)
      budget = Lain::Middleware::RequestBudget.new(journal: @journal, compaction: @source)
      Lain::Agent.new(
        provider: @provider, toolset:, context: @context, session: @session, journal: @journal,
        pipeline_source: @source, model_middleware: Lain::Middleware::Stack.new([budget]),
        turn_middleware: Lain::Middleware::Stack.new(
          [Lain::Middleware::JournalTurns.new(scribe: @scribe, timeline: -> { @agent.timeline })]
        )
      )
    end
  end
end

RSpec.describe "an :inherit child of a parent that compacted", :seam do
  around do |example|
    Dir.mktmpdir("inherit-child") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:context) { Lain::Context.new(model: "qwen3:4b", max_tokens: 64, system: "a system prompt") }
  let(:toolset) { Lain::Toolset.new([]) }
  let(:window) { Lain::ContextWindow.new(windows: { "qwen3" => 8192 }) }

  def chat(**) = InheritChildCompactionSeam::Chat.new(dir: @dir, context:, toolset:, window:, **)

  def handed_off(**)
    chat(**).tap do |parent|
      parent.fill
      parent.ask("so what is left to do?")
    end
  end

  def text_of(request) = Lain::Canonical.dump(request.messages)

  def child_requests(parent) = parent.child_provider.requests

  # A child's payment names its spawn and is the child's, not the parent's.
  def child_payment?(record) = record["type"] == "turn_usage" && record.key?("spawn")

  describe "spawned after a handoff" do
    it "sends the handoff document and not the replaced turns, and is answered" do
      parent = handed_off

      result = parent.spawn("write the parser")

      expect(parent.cuts.map { |cut| cut["kind"] }).to eq(["handoff"])
      expect(result).to be_ok
      first = text_of(child_requests(parent).first)
      expect(first).to include("finish the parser", "write the parser")
      expect(first).not_to include(InheritChildCompactionSeam::MARKER)
    end

    it "is refused over the window when it renders the raw inherited chain" do
      parent = handed_off

      expect { parent.spawn("write the parser", view: false) }
        .to raise_error(Lain::Middleware::RequestBudget::OverWindow, /subagent child/)
      expect(text_of(child_requests(parent).first)).to include(InheritChildCompactionSeam::MARKER)
    end
  end

  describe "spawned before any compaction" do
    it "sends the first request it sends today, byte for byte" do
      viewed = chat.tap { |parent| parent.ask("a short question") }
      today = chat.tap { |parent| parent.ask("a short question") }

      viewed.spawn("go")
      today.spawn("go", view: false)

      expect(text_of(child_requests(viewed).first)).to eq(text_of(child_requests(today).first))
    end
  end

  # The child pokes between its two renders; in one run the poke makes the
  # parent hand off a second time, in the other it does nothing.
  describe "the parent compacting later" do
    def poking_chat(&poke)
      parent = nil
      tool = InheritChildCompactionSeam::Poke.new { poke&.call(parent) }
      script = [Lain::Response.new(content: [{ "type" => "tool_use", "id" => "p1", "name" => "poke", "input" => {} }],
                                   stop_reason: :tool_use, usage: Lain::Usage.new(input_tokens: 40, output_tokens: 2))]
      parent = handed_off(child_script: script, child_tools: [tool])
    end

    def compacting_again(parent)
      2.times { |index| parent.ask("follow-up #{index}: #{InheritChildCompactionSeam::MARKER} #{"slept. " * 20}") }
    end

    it "leaves the child's next request as it would have been" do
      moved = poking_chat { |parent| compacting_again(parent) }
      still = poking_chat

      moved.spawn("write the parser")
      still.spawn("write the parser")

      expect(moved.cuts.size).to eq(2)
      expect(child_requests(moved).size).to eq(2)
      expect(text_of(child_requests(moved).last)).to eq(text_of(child_requests(still).last))
    end
  end

  describe "the parent" do
    def without_lineage(records)
      records.reject { |record| InheritChildCompactionSeam::LINEAGE.include?(record["type"]) || child_payment?(record) }
             .map { |record| record.except("ts", "wall_clock") }
    end

    it "journals the same records and sends the same next request with and without the spawn" do
      spawned = handed_off
      alone = handed_off

      spawned.spawn("write the parser")
      spawned.ask("and now?")
      alone.ask("and now?")

      expect(text_of(spawned.provider.requests.last)).to eq(text_of(alone.provider.requests.last))
      expect(without_lineage(spawned.records)).to eq(without_lineage(alone.records))
    end
  end

  # The child's own cut is the child's: with the parent's live session in its
  # place, the cut would land in the parent's record and on the parent's chain.
  describe "a child that compacts by itself" do
    def poke_call(id)
      Lain::Response.new(content: [{ "type" => "tool_use", "id" => id, "name" => "poke", "input" => {} }],
                         stop_reason: :tool_use, usage: Lain::Usage.new(input_tokens: 40, output_tokens: 2))
    end

    def compacting_chat(**)
      tool = InheritChildCompactionSeam::Poke.new(answer: "observed #{"at length " * 200}")
      handed_off(child_script: [poke_call("p1"), poke_call("p2"), poke_call("p3")], child_tools: [tool],
                 arm: "elide-tools", **)
    end

    def parent_side(records)
      lineage = InheritChildCompactionSeam::LINEAGE + %w[oracle_answer]
      records.reject { |record| lineage.include?(record["type"]) || child_payment?(record) }
             .map { |record| record.except("ts", "wall_clock") }
    end

    it "commits its cut in its own session, leaving the parent's cuts, records and next request as they were" do
      spawned = compacting_chat(child_compacts: true)
      alone = compacting_chat(child_compacts: true)

      expect(spawned.spawn("write the parser")).to be_ok
      expect(text_of(child_requests(spawned).last).scan("at length").size).to be < 600
      spawned.ask("and now?")
      alone.ask("and now?")

      expect(spawned.session.compaction_cuts).to eq(alone.session.compaction_cuts)
      expect(parent_side(spawned.records)).to eq(parent_side(alone.records))
      expect(text_of(spawned.provider.requests.last)).to eq(text_of(alone.provider.requests.last))
    end
  end

  describe "the session file it leaves" do
    it "loads, and its lineage holds the child's turns and none of the parent's" do
      parent = handed_off
      parent.spawn("write the parser")
      parent.close

      lineages = Lain::Bench::Session::Lineages.of(Lain::Bench::Session.load(parent.lines)).to_a

      expect(lineages.size).to eq(1)
      turns = lineages.first.child_turns
      expect(turns.first.parent).to eq(lineages.first.spawned_from)
      expect(turns.map(&:digest) & parent.agent.timeline.ancestor_digests).to be_empty
      expect(turns.map { |turn| turn.content.first["text"] }).to eq(["write the parser", "settled"])
    end
  end
end
