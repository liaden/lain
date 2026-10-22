# frozen_string_literal: true

require "stringio"

# A session file whose parent spawned one subagent per [role, answer], each
# announced as that role, recorded by a real {Lain::SessionRecord::Scribe}.
class RoleSession
  include MockRecording

  def self.lines(*roles) = new.lines(*roles)

  # @return [Array<String>] the NDJSON lines
  def lines(*roles)
    io = StringIO.new
    agent = scribe = nil
    observer = ->(event) { scribe.call(event) }
    parent = -> { agent.timeline }
    toolset = Lain::Toolset.new(roles.map { |role, answer| spawner(role, answer, parent:, observer:) })
    journal = Lain::Journal.new(io:)
    scribe = Lain::SessionRecord::Scribe.new(journal:, context: RecordedSpawnSession::CONTEXT, toolset:)
    agent = parent_agent(roles, toolset:, journal:, scribe:, parent:)
    agent.ask("go")
    scribe.catch_up(agent.timeline)
    scribe.close(reason: :exit)
    io.string.each_line.to_a
  end

  def parent_agent(roles, toolset:, journal:, scribe:, parent:)
    script = roles.each_with_index.map do |(role, _), i|
      tool_response(["tu_#{i}", role, { "prompt" => "task #{i}" }])
    end
    Lain::Agent.new(
      provider: Lain::Provider::Mock.new(responses: [*script, text_response("done")]),
      context: RecordedSpawnSession::CONTEXT, toolset:, journal:, timeline: CoreGraph.timeline,
      turn_middleware: Lain::Middleware::Stack.new([Lain::Middleware::JournalTurns.new(scribe:, timeline: parent)])
    )
  end

  def spawner(role, answer, parent:, observer:)
    provider = Lain::Provider::Mock.new(responses: [text_response(answer)])
    Lain::Tools::Subagent.new(
      seam: Lain::Tools::Subagent::Seam.new(
        tool_middleware: ToolRegistry::UNGUARDED, provider:, parent:, observer:,
        context_factory: -> { RecordedSpawnSession::CHILD_CONTEXT }, holder: Lain::Tools::Subagent::Holder.at(2)
      ),
      toolset: Lain::Toolset.new([EchoTool.new]), name: role, announces_as: Lain::Requester.new(name: role, role:),
      policy: Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: [])
    )
  end
end
