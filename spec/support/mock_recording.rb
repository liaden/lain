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
end

RSpec.configure { |config| config.include MockRecording }
