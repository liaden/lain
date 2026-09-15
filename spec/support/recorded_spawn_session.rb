# frozen_string_literal: true

require "json"
require "stringio"

# The lineage-bearing records of a session file exactly as a chat that spawned
# subagents writes them: a real parent {Lain::Agent} over
# {Lain::Provider::Mock}, the real {Lain::Tools::Subagent} in its toolset, and a
# real {Lain::SessionRecord::Scribe} both observing the spawn funnel and catching
# up after every iteration -- the wiring {Lain::CLI::Chronicle} gives a chat. The
# parent journals its `turn_usage`; nothing writes `request_sent`, so a
# request-replay baseline is not what these files exercise.
#
# It exists so a lineage reader is specced against the shape production
# writes -- a `:spawn` and a completion `message`, the child's turns as
# `child_turn` records -- rather than against one a spec invented. Inventing one
# is how every reader came to walk `meta["spawned_from"]` on `turn` records,
# which nothing ever wrote.
class RecordedSpawnSession
  CONTEXT = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse")
  CHILD_CONTEXT = Lain::Context.new(model: "child-model", max_tokens: 256)

  # What {#run} asks by default. Named, because a fresh child given the same
  # text commits the very same root turn, and a spec about that case says so.
  OPENING = "please spawn"

  # A child tool that copies the session's bytes as they stand at the moment it
  # is called: what a reader opening a LIVE session file would see.
  class Snapshot < Lain::Tool
    def initialize(&capture)
      super()
      @capture = capture
    end

    def name = "snapshot"
    def description = "Copies the session file as it stands."
    def input_schema = { type: :object, properties: {} }

    def perform(_input, _context)
      @capture.call
      Lain::Tool::Result.ok("snapshot taken")
    end
  end

  attr_reader :agent, :snapshots

  # @param parent_responses [Array<Lain::Response>] the parent's script
  # @param child_responses [Array<Lain::Response>] every child's script, in
  #   spawn order: one Mock backs every spawn, so siblings consume it in turn
  # @param prefix [Symbol] the spawn policy's prefix arm
  # @param tools [Array<Lain::Tool>] the parent's tools beside the subagent
  # @param child_tools [Array<Lain::Tool>] the tools every child holds, beside
  #   `snapshot`
  # @param grandchild_responses [Array<Lain::Response>, nil] when given, every
  #   child also holds a subagent, whose children run this script
  # @param resuming [Array(RecordedSpawnSession, String), nil] a prior run and
  #   the basename it is written under: this session continues its head
  def initialize(parent_responses:, child_responses:, prefix: :fresh, tools: [EchoTool.new],
                 child_tools: [EchoTool.new], grandchild_responses: nil, resuming: nil)
    @io = StringIO.new
    @agent = nil
    @snapshots = []
    child_tools = [*child_tools, Snapshot.new { @snapshots << @io.string.dup }]
    child_tools << subagent(grandchild_responses, prefix, child_tools, depth: 1) unless grandchild_responses.nil?
    toolset = Lain::Toolset.new([*tools, subagent(child_responses, prefix, child_tools, depth: 2)])
    @journal = Lain::Journal.new(io: @io)
    @scribe = Lain::SessionRecord::Scribe.new(journal: @journal, context: CONTEXT, toolset:, **resumed(resuming))
    @agent = parent(parent_responses, toolset, resuming)
  end

  # One ask, recorded and closed: the file a reader finds on disk.
  #
  # @return [self]
  def run(prompt = OPENING)
    @agent.ask(prompt)
    @scribe.catch_up(@agent.timeline)
    @scribe.close(reason: :exit)
    @records = nil
    self
  end

  # @return [Array<String>] the NDJSON lines, newline-terminated
  def lines = @io.string.each_line.to_a

  def records = @records ||= lines.map { |line| JSON.parse(line) }

  def of_type(type) = records.select { |record| record["type"] == type }

  # @return [String] `path`, written
  def write(path)
    File.write(path, @io.string)
    path
  end

  private

  # Journaled as a chat's parent is: each committed assistant turn's record,
  # then its `turn_usage`, land before its tool calls run.
  def parent(responses, toolset, resuming)
    Lain::Agent.new(
      provider: Lain::Provider::Mock.new(responses:), context: CONTEXT, toolset:, journal: @journal,
      timeline: resuming.nil? ? Lain::Timeline.empty(store: Lain::Store.new) : resuming.first.agent.timeline,
      turn_middleware: Lain::Middleware::Stack.new(
        [Lain::Middleware::JournalTurns.new(scribe: @scribe, timeline: -> { @agent.timeline })]
      )
    )
  end

  # A resumed record names its prior file and head, and is seeded with the
  # prior file's turns so it does not write them again.
  def resumed(resuming)
    return {} if resuming.nil?

    prior, file = resuming
    chain = prior.agent.timeline
    { resumed_from: { "file" => file, "head" => chain.head_digest }, written: chain.ancestor_digests.reverse }
  end

  # Late-bound on the parent's LIVE head, the thunk the exe hands a subagent. A
  # nested spawn reads its parent off the child that runs it, never this thunk.
  def subagent(responses, prefix, child_tools, depth:)
    Lain::Tools::Subagent.new(
      seam: Lain::Tools::Subagent::Seam.new(
        tool_middleware: ToolRegistry::UNGUARDED, provider: Lain::Provider::Mock.new(responses:),
        context_factory: -> { CHILD_CONTEXT }, parent: -> { @agent.timeline },
        observer: ->(event) { @scribe.call(event) }
      ),
      toolset: Lain::Toolset.new(child_tools),
      policy: Lain::Tool::SpawnPolicy.new(prefix:, posture: :schema, only: []),
      max_depth: depth
    )
  end
end
