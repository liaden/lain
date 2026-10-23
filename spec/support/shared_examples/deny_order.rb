# frozen_string_literal: true

# A tool stack whose gate was handed a config's `deny_tool`. The host supplies
# the stack under test, the call to dispatch and the journal the gate writes to.
RSpec.shared_examples "a deny is never loosened" do
  # host lets: stack (Middleware::Stack), effect (Effect::ToolCall), context, journal (Array)
  let(:toolset) { Lain::Toolset.new([Lain::Tools::WriteFile.new, Lain::Tools::Bash.new]) }
  let(:refusal) { format(Lain::Middleware::Gate::TOOL_REFUSED, effect.name) }

  def dispatched
    dispatch_call(effect.name, effect.input, toolset:, layers: stack.to_a, context:)
  end

  it "answers the gate's final config refusal" do
    expect(dispatched).to have_attributes(is_error: true, content: include(refusal))
  end

  it "records an escalation naming the config rung" do
    dispatched

    expect(journal).to include(a_hash_including("type" => "escalation", "rung" => "config", "verdict" => "deny"))
  end
end
