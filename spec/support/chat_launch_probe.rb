# frozen_string_literal: true

require "stringio"

# A `lain chat` launched through the real {Lain::CLI::ChatLaunch} bracket, the
# real {Lain::CLI::Backend} and the real {Lain::CLI::Wiring#wire_agent}, stopped
# the moment the agent exists. Only three edges are faked: the provider (no
# network), the record (an in-memory journal) and the daily reap (no spawned
# process). So a flag that reaches the agent or the session header here reached
# it through every copy the chat path makes -- `Switchboard#graft`'s
# `with_model` included -- which a spec building a Context by hand cannot say.
module ChatLaunchProbe
  STOP = "chat launch probe: stopped once the agent was wired"

  # The launch's own options decide everything but the network edge.
  class Backend < Lain::CLI::Backend
    def provider(**) = Lain::Provider::Mock.new(responses: [])
  end

  class Launch < Lain::CLI::ChatLaunch
    def backend = @backend ||= Backend.new(@options)
  end

  class Wiring < Lain::CLI::Wiring
    attr_reader :agent

    def run(backend:, resumed:, nvim:)
      recorder, session = run_state(resumed)
      @agent = wire_agent(channel: Lain::Channel.new, recorder:, session:, backend:, resumed:, views: nvim)
      raise Lain::Error, STOP
    end
  end

  LAUNCH_DEFAULTS = { journal: false, provider: "ollama", model: nil, max_tokens: 64, grace: 5 }.freeze

  # @return [Array(Lain::Agent, Array<Hash>)] the wired agent and the records
  #   the session journal received
  def launch_chat(options, root:)
    io = StringIO.new
    wiring = nil
    launch = Launch.new(LAUNCH_DEFAULTS.merge(options), **probe_factories(root:, io:) { |built| wiring = built })
    begin
      launch.call { |_notice| nil }
    rescue Lain::Error => e
      raise unless e.message == STOP
    end
    [wiring.agent, io.string.each_line.map { |line| JSON.parse(line) }]
  end

  private

  def probe_factories(root:, io:, &built)
    project = Lain::Project.new(root:, cwd: root, kind: :project, detected_by: :flag)
    { wiring_factory: ->(**kwargs) { Wiring.new(**kwargs).tap(&built) },
      chronicle_factory: lambda { |**|
        Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io:), journal_path: "probe.ndjson")
      },
      project_factory: -> { project },
      gc_schedule_factory: ->(root:) { -> { root } } }
  end
end
