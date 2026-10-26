# frozen_string_literal: true

# The scripted capability most mock-driven specs share: echoes its input back,
# so a tool_result's bytes are a pure function of the scripted tool_use input.
# (lib/lain/bench/variance_fixtures.rb keeps its own scripted tool on purpose:
# the committed fixture bytes must not couple to spec helpers.)
class EchoTool < Lain::Tool
  def name = "echo"
  def description = "Echoes its input back."
  def input_schema = { type: :object, properties: { text: { type: :string } }, required: [:text] }

  def perform(input, _context) = Lain::Tool::Result.ok(input.fetch("text"))
end

# Its counterpart for the error path.
class BoomTool < Lain::Tool
  def name = "boom"
  def description = "Always explodes."
  def input_schema = { type: :object, properties: {} }

  def perform(_input, _context) = raise("kaboom")
end

# The mock-recording idiom, shared across the suite: scripted Responses driven
# through a real Agent over Provider::Mock. Per-spec variation (usage, model,
# thinking blocks, journaling, workspace) is said at the call site.
module MockRecording
  def text_response(text = "done", stop_reason: :end_turn, **attrs)
    Lain::Response.new(content: [{ "type" => "text", "text" => text }], stop_reason:, **attrs)
  end

  # Each call is an [id, name, input] triple. `thinking:` prepends a thinking
  # block, exercising the mixed content real tool_use responses carry.
  def tool_response(*calls, thinking: nil, **attrs)
    blocks = calls.map { |(id, name, input)| { "type" => "tool_use", "id" => id, "name" => name, "input" => input } }
    blocks.unshift({ "type" => "thinking", "thinking" => thinking }) unless thinking.nil?
    Lain::Response.new(content: blocks, stop_reason: :tool_use, **attrs)
  end

  # One ask through a real Agent over a Provider::Mock scripted with
  # `responses`. Returns [agent, provider] -- the provider retains the Requests
  # it was actually handed, the recorded baseline. Extra kwargs flow to
  # Agent.new.
  def record_run(responses, toolset:, context:, prompt: "please echo hi", **agent_options)
    provider = Lain::Provider::Mock.new(responses:)
    agent = Lain::Agent.new(provider:, toolset:, context:, **agent_options)
    agent.ask(prompt)
    [agent, provider]
  end

  # The full record-a-session wiring: the Agent journals turn_usage, and an
  # INNERMOST JournalRequests records the bytes the provider actually received.
  def record_journaled_run(responses, journal:, **)
    stack = Lain::Middleware::Stack.new([Lain::Middleware::JournalRequests.new(journal:)])
    record_run(responses, journal:, model_middleware: stack, **)
  end

  # What `lain chat --compact-strategy <strategy> --compact-keep <keep>` builds its compaction
  # from, at thresholds low enough that seven long tool rounds commit two elide cuts.
  def compacting_backend(strategy: "elide", keep: 2)
    Lain::CLI::Backend.new({ provider: "anthropic", model: "claude-opus-4-8", max_tokens: 1024, compact_bytes: 3_000,
                             compact_cap: 3_000, compact_strategy: strategy, compact_keep: keep }, root: Dir.pwd)
  end

  # A journaled run through `backend`'s own pipeline source. Its cuts land wherever `session`
  # journals, which is `journal` for a session built on it.
  def record_compacted_run(journal:, session:, backend: compacting_backend, rounds: 7, **)
    calls = Array.new(rounds) { |index| tool_response(["tu_#{index}", "echo", { "text" => "hi #{index} " * 120 }]) }
    pipeline_source = backend.pipeline_source(cache_profile: { ttl: nil }, journal:)
    record_journaled_run(calls + [text_response("done")], journal:, session:, pipeline_source:,
                                                          prompt: "please echo a lot " * 20, **)
  end

  # Six asks answered in long text, so no tool pair pulls the cut back from the
  # keep_last boundary: a replay under a larger keep than the run's then refuses
  # a cut the run held.
  def record_compacted_chat(journal:, session:, toolset:, context:, backend: compacting_backend, **)
    provider = Lain::Provider::Mock.new(responses: Array.new(6) { |index| text_response("an answer #{index} " * 40) })
    stack = Lain::Middleware::Stack.new([Lain::Middleware::JournalRequests.new(journal:)])
    agent = Lain::Agent.new(provider:, toolset:, context:, journal:, session:, model_middleware: stack,
                            pipeline_source: backend.pipeline_source(cache_profile: { ttl: nil }, journal:), **)
    6.times { |index| agent.ask("turn #{index} " * 40) }
    [agent, provider]
  end

  # Read off the record rather than any replay: the cut each request_sent rendered through is
  # the newest compaction_cut written ahead of it, named by address because a collapse
  # shares its digest with the advance it rewrites.
  def cuts_in_force(records)
    records.each_index.select { |index| records[index]["type"] == "request_sent" }.map do |index|
      ahead = records.take(index).reverse.find { |record| record["type"] == "compaction_cut" }
      ahead && Lain::Telemetry::CompactionCut.new(**ahead.slice(*CUT_FIELDS).transform_keys(&:to_sym)).address
    end
  end

  CUT_FIELDS = Lain::Telemetry::CompactionCut.members.map(&:to_s).freeze
  private_constant :CUT_FIELDS
end

RSpec.configure { |config| config.include MockRecording }
