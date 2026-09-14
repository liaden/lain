# frozen_string_literal: true

# One tool call driven through a REAL {Lain::Agent::ToolRunner}, which is the
# one place the tool is resolved and the stack meets its interpreter. A spec
# that assembled `env -> env.merge(result:)` itself would be testing its own
# copy of that adapter, so every example that needs a whole tool-phase dispatch
# comes through here instead.
module ToolDispatch
  # @param name [String] the tool the model asks for
  # @param input [Hash] its input, as the provider would hand it over
  # @param toolset [#fetch] what the runner resolves the name against
  # @param layers [Array<#call>] the tool-phase middleware, outermost first
  # @param handler [Lain::Effect::Handler] the interpreter at the end
  # @param context [Object, nil] threaded to the tool's invocation
  # @param id [String] the tool_use id
  # @return [Lain::Tool::Result] rebuilt from the tool_result block the runner
  #   committed, so an assertion reads what the model is told
  def dispatch_call(name, input = {}, toolset:, layers: [], handler: Lain::Effect::Handler::Live.new,
                    context: nil, id: "tu_1")
    response = Lain::Response.new(content: [{ "type" => "tool_use", "id" => id, "name" => name, "input" => input }],
                                  stop_reason: :tool_use)
    runner = Lain::Agent::ToolRunner.new(handler:, middleware: Lain::Middleware::Stack.new(layers), toolset:)
    block = runner.run(response, context:).first
    block["is_error"] ? Lain::Tool::Result.error(block["content"]) : Lain::Tool::Result.ok(block["content"])
  end
end

RSpec.configure { |config| config.include ToolDispatch }
